defmodule Long.Agent.PythonRunner do
  @moduledoc """
  Shared port-handling plumbing for both `Long.Agent.Tools.CodeRun`
  (streaming) and `Long.Jido.Tools.CodeRun` (collected). Each tool
  owns its own receive loop — what they share is command building,
  PATH setup, port cleanup, and output truncation.
  """

  alias Long.Agent.{DenoEnv, PythonEnv}

  @type build_result ::
          {:ok, exe :: String.t(), args :: [String.t()], cleanup :: (-> any())}
          | {:error, String.t()}

  @doc "Map language aliases to the canonical type. Anything else passes through."
  def normalize_type("py"), do: "python"
  def normalize_type("shell"), do: "bash"
  def normalize_type("sh"), do: "bash"
  def normalize_type("js"), do: "deno"
  def normalize_type("ts"), do: "deno"
  def normalize_type("javascript"), do: "deno"
  def normalize_type("typescript"), do: "deno"
  def normalize_type(t), do: t

  @doc """
  Build the executable + args + cleanup callback for a given snippet type.
  Writes a temp file for Python and returns a cleanup fn that removes it.
  Bash and powershell run inline.
  """
  @spec build_command(String.t(), String.t(), String.t()) :: build_result()
  def build_command(code, "python", cwd) do
    case PythonEnv.uv_bin() do
      {:error, :uv_missing} ->
        {:error,
         "uv not installed. Install from https://docs.astral.sh/uv/ and retry " <>
           "(the workspace at #{PythonEnv.root()} is uv-managed)."}

      {:ok, uv} ->
        tmp = Path.join(cwd, ".ai_#{System.unique_integer([:positive])}.py")
        File.write!(tmp, code)
        {:ok, uv, ["run", "python", "-X", "utf8", "-u", tmp], fn -> File.rm(tmp) end}
    end
  end

  def build_command(code, "deno", cwd) do
    case DenoEnv.deno_bin() do
      {:error, :deno_missing} ->
        {:error,
         "deno not installed. Install from https://deno.land/ (or `brew install deno`) and retry."}

      {:ok, deno} ->
        tmp = Path.join(cwd, ".ai_#{System.unique_integer([:positive])}.ts")
        File.write!(tmp, code)
        {:ok, deno, deno_args(cwd, tmp), fn -> File.rm(tmp) end}
    end
  end

  def build_command(code, "bash", _cwd), do: {:ok, "bash", ["-c", code], fn -> :ok end}

  def build_command(_code, "powershell", _cwd) do
    if match?({:win32, _}, :os.type()) do
      {:ok, "powershell", ["-NoProfile", "-NonInteractive", "-Command"], fn -> :ok end}
    else
      {:error, "powershell only supported on Windows"}
    end
  end

  def build_command(_code, type, _cwd), do: {:error, "unsupported code_type: #{type}"}

  # Deno permission flags, scoped to the member's workspace `cwd`. We grant
  # filesystem read/write only *inside* that directory (multi-member
  # isolation), plus network; everything else — subprocess (`--allow-run`),
  # FFI, env — stays denied. `--no-prompt` makes a missing permission a hard
  # deny instead of a hang waiting on a TTY that isn't there.
  defp deno_args(cwd, tmp) do
    [
      "run",
      "--quiet",
      "--no-prompt",
      "--allow-read=#{cwd}",
      "--allow-write=#{cwd}",
      "--allow-net",
      tmp
    ]
  end

  @doc """
  PATH env for child processes: prepend the workspace's `.venv/bin` and
  the workspace root itself (which holds the python/python3 shims). This
  lets `uv add`-installed console scripts and bare `python` calls in
  bash heredocs resolve cleanly.
  """
  def port_env(workspace) do
    venv_bin = Path.join([workspace, ".venv", "bin"])
    parent = System.get_env("PATH") || ""
    [{~c"PATH", String.to_charlist(Enum.join([venv_bin, workspace, parent], ":"))}]
  end

  @doc """
  Best-effort port + OS-process termination. `Port.close/1` alone only
  sends SIGTERM, which a busy-loop Python script (`while True: pass`,
  pegged C extension, …) ignores until the next scheduler tick — that
  leaves an orphan process pegging CPU while the BEAM has already
  released the port. Send SIGKILL first when the port is still alive,
  then close.

  Mirrors `Long.Agent.Browser.Cli.brutal_kill/1` — kept as a separate
  function rather than a shared helper because the only two callers
  live in unrelated subsystems.
  """
  def kill_port(port) do
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

  @doc """
  Truncate an output string to `max` bytes by keeping the head and tail
  with a marker in the middle. Useful for long stdout/stderr captures.
  """
  def truncate(s, max) when is_binary(s) and byte_size(s) > max,
    do: Long.Util.Utf8.head_tail(s, max, "\n\n[omitted long output]\n\n")

  def truncate(s, _), do: s
end
