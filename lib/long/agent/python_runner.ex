defmodule Long.Agent.PythonRunner do
  @moduledoc """
  Shared port-handling plumbing for both `Long.Agent.Tools.CodeRun`
  (streaming) and `Long.Jido.Tools.CodeRun` (collected). Each tool
  owns its own receive loop — what they share is command building,
  PATH setup, port cleanup, and output truncation.
  """

  alias Long.Agent.PythonEnv

  @type build_result ::
          {:ok, exe :: String.t(), args :: [String.t()], cleanup :: (-> any())}
          | {:error, String.t()}

  @doc "Map `py | shell | sh` aliases to the canonical type. Anything else passes through."
  def normalize_type("py"), do: "python"
  def normalize_type("shell"), do: "bash"
  def normalize_type("sh"), do: "bash"
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

  def build_command(code, "bash", _cwd), do: {:ok, "bash", ["-c", code], fn -> :ok end}

  def build_command(_code, "powershell", _cwd) do
    if match?({:win32, _}, :os.type()) do
      {:ok, "powershell", ["-NoProfile", "-NonInteractive", "-Command"], fn -> :ok end}
    else
      {:error, "powershell only supported on Windows"}
    end
  end

  def build_command(_code, type, _cwd), do: {:error, "unsupported code_type: #{type}"}

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

  @doc "Best-effort port close; swallow already-closed errors."
  def kill_port(port) do
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
  def truncate(s, max) when byte_size(s) > max do
    half = div(max, 2)
    binary_part(s, 0, half) <>
      "\n\n[omitted long output]\n\n" <>
      binary_part(s, byte_size(s) - half, half)
  end

  def truncate(s, _), do: s
end
