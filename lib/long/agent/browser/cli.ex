defmodule Long.Agent.Browser.Cli do
  @moduledoc """
  One-shot wrapper around `obscura fetch …`. Each call spawns a fresh
  browser; concurrent calls are bounded by `Cli.Limiter`. Returns
  `{:error, :not_installed}` until `Browser.Engine`'s background
  installer finishes downloading the binary.
  """

  alias Long.Agent.Browser.Cli.Limiter
  alias Long.Agent.Browser.Installer

  @default_timeout_s 25
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
    * `:timeout_s` — max navigation time in seconds (default 25).
    * `:stealth` — pass `--stealth`; default true.
    * `:runner` — injection point for tests; defaults to
      `&System.cmd/3`. Signature: `(bin, args, opts) -> {output, exit}`.
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

  Same `:wait_until` / `:timeout_s` / `:stealth` / `:runner` options as
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
    runner = Keyword.get(opts, :runner, &System.cmd/3)
    cmd_opts = [stderr_to_stdout: false]
    use_limiter? = Keyword.get(opts, :limiter, true)

    work = fn ->
      try do
        case runner.(bin, args, cmd_opts) do
          {output, 0} -> {:ok, output}
          {output, exit_status} -> {:error, {:cli_exit, exit_status, String.trim(output)}}
        end
      rescue
        e in [ErlangError, File.Error] -> {:error, {:cli_crash, Exception.message(e)}}
      end
    end

    if use_limiter? and limiter_available?() do
      Limiter.with_slot(work)
    else
      work.()
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
