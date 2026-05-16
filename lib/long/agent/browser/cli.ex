defmodule Long.Agent.Browser.Cli do
  @moduledoc """
  One-shot wrapper around `obscura fetch …`. Each call spawns a fresh
  browser; concurrent calls are bounded by `Cli.Limiter`. Returns
  `{:error, :not_installed}` until `Browser.Engine`'s background
  installer finishes downloading the binary.
  """

  alias Long.Agent.Browser.Cli.Limiter
  alias Long.Agent.Browser.Installer

  # Single navigation cap. 30s is enough for any reasonable page on a
  # decent connection; longer means the page is broken or stuck (ads
  # keeping `networkidle0` from ever firing, etc.) — we'd rather give
  # up and let the circuit breaker mark the URL dead than burn another
  # Loop turn on it.
  @default_timeout_s 30
  # External hard cap = obscura's own `--timeout` + a 60s buffer to
  # cover wait / eval / dump / serialization phases. If we hit this,
  # obscura itself has hung (deno stack overflow, infinite JS loop on
  # the target page, …) and is *not* honoring its internal timeout;
  # we have to SIGKILL it from the BEAM side or it pegs a CPU forever.
  @hard_timeout_buffer_ms 60_000
  # `networkidle0` waits until all network requests have settled — the
  # right default for modern SPAs (Reuters, TechCrunch, OpenAI's site,
  # …) that hydrate the body client-side. `load` returns after the
  # initial HTML response, which on those sites is just an empty `<title>`
  # + script shell.
  @default_wait_until "networkidle0"

  @doc "Return the binary path or `{:error, :not_installed}`."
  @spec binary_path() :: {:ok, String.t()} | {:error, :not_installed}
  def binary_path do
    case Installer.locate() do
      nil -> {:error, :not_installed}
      path -> {:ok, path}
    end
  end

  @doc "True if `obscura` is on PATH or in the project-local bin dir."
  @spec available?() :: boolean()
  def available? do
    case binary_path() do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  `obscura fetch URL --eval JS_EXPR`. Returns the stdout from Obscura
  as a string — the caller decides how to interpret it (JSON-decode,
  trim, etc.).

  ## Options

    * `:wait_until` — `"load"` (default) | `"domcontentloaded"` |
      `"networkidle0"`. Use `networkidle0` for JS-heavy SPAs.
    * `:timeout_s` — max navigation time in seconds (default 30).
    * `:stealth` — pass `--stealth`; default true.
    * `:limiter` — bypass the concurrency limiter (default true).
  """
  @spec eval(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def eval(url, js_expr, opts \\ []) when is_binary(url) and is_binary(js_expr) do
    with {:ok, bin} <- binary_path() do
      args =
        [
          "fetch",
          url,
          "--eval",
          js_expr,
          "--wait-until",
          Keyword.get(opts, :wait_until, @default_wait_until),
          "--timeout",
          to_string(Keyword.get(opts, :timeout_s, @default_timeout_s)),
          "--quiet"
        ]
        |> maybe_add_stealth(opts)

      run(bin, args, opts)
    end
  end

  @doc """
  `obscura fetch URL --dump <format>`. Returns the rendered output as a
  string. Format options:

    * `:html` (default) — full DOM after JS rendering
    * `:text` — text-only extraction
    * `:markdown` — readability-style markdown
    * `:links` — newline-separated link list

  Same `:wait_until` / `:timeout_s` / `:stealth` / `:limiter` options as
  `eval/3`.
  """
  @spec dump(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def dump(url, opts \\ []) when is_binary(url) do
    with {:ok, bin} <- binary_path() do
      format = opts |> Keyword.get(:format, :html) |> to_string()

      args =
        [
          "fetch",
          url,
          "--dump",
          format,
          "--wait-until",
          Keyword.get(opts, :wait_until, @default_wait_until),
          "--timeout",
          to_string(Keyword.get(opts, :timeout_s, @default_timeout_s)),
          "--quiet"
        ]
        |> maybe_add_stealth(opts)

      run(bin, args, opts)
    end
  end

  # ── internals ───────────────────────────────────────────────────────

  # Wraps the actual subprocess spawn in a semaphore so we never have
  # more than `Limiter`'s max concurrent obscura processes alive (each
  # uses 200-400 MB; WSL2 / small machines OOM at 4+). Tests can
  # bypass the limiter by passing `limiter: false` to the call so
  # async_stream'd assertions don't serialize through the singleton.
  defp run(bin, args, opts) do
    hard_timeout_ms = Keyword.get(opts, :timeout_s, @default_timeout_s) * 1_000 + @hard_timeout_buffer_ms

    work = fn -> spawn_and_collect(bin, args, hard_timeout_ms) end

    if Keyword.get(opts, :limiter, true) and limiter_available?() do
      Limiter.with_slot(work)
    else
      work.()
    end
  end

  # Port-based spawn so we can SIGKILL the OS process when it ignores
  # its own internal `--timeout` (deno stack overflow on the target
  # page, infinite JS loop, …). `System.cmd/3` doesn't expose the OS
  # pid and blocks the caller forever in that case.
  defp spawn_and_collect(bin, args, hard_timeout_ms) do
    port =
      Port.open(
        {:spawn_executable, bin},
        [:binary, :exit_status, {:args, args}]
      )

    deadline = System.monotonic_time(:millisecond) + hard_timeout_ms
    collect_output(port, [], deadline, hard_timeout_ms)
  rescue
    e -> {:error, {:cli_crash, Exception.message(e)}}
  end

  # iolist accumulator — obscura `--dump html` on a heavy SPA can be
  # multiple MB and we'd otherwise do O(n²) binary copies on each
  # `:data` chunk.
  defp collect_output(port, acc, deadline, hard_timeout_ms) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, chunk}} ->
        collect_output(port, [acc, chunk], deadline, hard_timeout_ms)

      {^port, {:exit_status, 0}} ->
        {:ok, IO.iodata_to_binary(acc)}

      {^port, {:exit_status, status}} ->
        {:error, {:cli_exit, status, acc |> IO.iodata_to_binary() |> String.trim()}}
    after
      remaining ->
        brutal_kill(port)
        {:error, {:hard_timeout, div(hard_timeout_ms, 1_000)}}
    end
  end

  # `Port.close/1` alone only sends SIGTERM and waits politely — useless
  # against a runaway obscura already ignoring its own timeout. Send
  # SIGKILL to the OS pid first so the kernel terminates it, then close
  # the port to drain.
  defp brutal_kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> _ = System.cmd("kill", ["-9", to_string(pid)])
      _ -> :ok
    end

    try do
      Port.close(port)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  # Limiter is started by the application supervisor. In tests or
  # contexts where it isn't running we just skip and let the BEAM
  # schedule freely.
  defp limiter_available?, do: Process.whereis(Limiter) != nil

  defp maybe_add_stealth(args, opts) do
    if Keyword.get(opts, :stealth, true), do: args ++ ["--stealth"], else: args
  end
end
