defmodule Long.Agent.CodeRunner do
  @moduledoc """
  Shared port-handling plumbing for the `code_run` tools — command
  building, PATH setup, port cleanup, and output truncation. Each tool
  owns its own receive loop.

  Code runs on **Deno** (the default, sandboxed to the member's
  workspace) or **bash** (shell / system commands). There is no Python
  backend.
  """

  alias Long.Agent.DenoEnv

  @type build_result ::
          {:ok, exe :: String.t(), args :: [String.t()], cleanup :: (-> any())}
          | {:error, String.t()}

  @doc "Map language aliases to the canonical type. Anything else passes through."
  def normalize_type("shell"), do: "bash"
  def normalize_type("sh"), do: "bash"
  def normalize_type("js"), do: "deno"
  def normalize_type("ts"), do: "deno"
  def normalize_type("javascript"), do: "deno"
  def normalize_type("typescript"), do: "deno"
  def normalize_type(t), do: t

  @doc """
  Build the executable + args + cleanup callback for a snippet type.
  Deno writes a temp `.ts` and runs sandboxed; bash runs inline.
  """
  @spec build_command(String.t(), String.t(), String.t()) :: build_result()
  def build_command(code, "deno", cwd) do
    with {:ok, deno} <- deno_exe() do
      tmp = Path.join(cwd, ".ai_#{System.unique_integer([:positive])}.ts")
      File.write!(tmp, code)
      {:ok, deno, deno_args(cwd, tmp), fn -> File.rm(tmp) end}
    end
  end

  # `bash` is intentionally NOT sandboxed — it runs with the server's full
  # host access (the Deno path is the sandboxed one). This is a trusted-
  # deployment assumption (family / LAN), not a containment boundary against
  # an untrusted member. `blocked_interpreter/1` only stops bash from being
  # used to jump to another *language runtime* and bypass the Deno sandbox.
  def build_command(code, "bash", _cwd) do
    case blocked_interpreter(code) do
      nil ->
        {:ok, "bash", ["-c", code], fn -> :ok end}

      tool ->
        {:error,
         "`#{tool}` is not available — code execution is Deno-only. Write the logic in " <>
           "TypeScript/JavaScript and run it with code_run (type: \"deno\", the default) " <>
           "instead of shelling out to #{tool}."}
    end
  end

  def build_command(_code, "powershell", _cwd) do
    if match?({:win32, _}, :os.type()) do
      {:ok, "powershell", ["-NoProfile", "-NonInteractive", "-Command"], fn -> :ok end}
    else
      {:error, "powershell only supported on Windows"}
    end
  end

  def build_command(_code, type, _cwd), do: {:error, "unsupported code_type: #{type}"}

  @doc """
  Build a command to run an existing `.ts`/`.js` file on Deno, sandboxed to
  `cwd` with the same permission flags as inline code. Lets the model run a
  saved/companion script without shelling out to `node`/`python`.
  """
  def build_deno_file(abs_path, cwd) do
    with {:ok, deno} <- deno_exe() do
      {:ok, deno, deno_args(cwd, abs_path), fn -> :ok end}
    end
  end

  defp deno_exe do
    case DenoEnv.deno_bin() do
      {:ok, deno} ->
        {:ok, deno}

      {:error, :deno_missing} ->
        {:error,
         "deno not available. It auto-installs at boot; if this persists, install from " <>
           "https://deno.land/ or set `config :long, Long.Agent.Deno, auto_install: true`."}
    end
  end

  # Language runtimes we deliberately keep out of reach in `bash`: code
  # execution is Deno-only, so the model can't fall back to writing a script
  # in another language (`.py`, `.js`, …) and running it through its
  # interpreter — which would also escape Deno's per-member sandbox, since
  # those runtimes get full host access. Override via
  # `config :long, Long.Agent, blocked_interpreters: [...]`.
  @default_blocked ~w(
    python python2 python3 pip pip2 pip3 pipx uv poetry pyenv conda virtualenv
    node nodejs npm npx bun bunx deno ts-node tsx
    ruby gem bundle perl php Rscript lua
  )

  # Match a blocked name only at a *command* position — line start, after a
  # shell separator (`;` `|` `&` `(` newline backtick), or after `env ` —
  # with an optional path prefix (`/usr/bin/python3`). So `python3 x.py` and
  # `cat a | node b` are caught, while `ls node_modules` / `cat foo.py` are not.
  @blocked_re_template ~S{(?:^|[\n;&|(`]|\benv\s+)\s*(?:\S*/)?(NAMES)\b}
  @default_blocked_re Regex.compile!(String.replace(@blocked_re_template, "NAMES", Enum.join(@default_blocked, "|")))

  defp blocked_interpreter(code) do
    case Regex.run(blocked_re(), code, capture: :all_but_first) do
      [hit | _] -> hit
      _ -> nil
    end
  end

  # Use the regex compiled once at load, unless the blocklist is overridden.
  defp blocked_re do
    case Application.get_env(:long, Long.Agent, [])[:blocked_interpreters] do
      nil -> @default_blocked_re
      names -> Regex.compile!(String.replace(@blocked_re_template, "NAMES", Enum.join(names, "|")))
    end
  end

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

  @doc "PATH env for child processes: prepend the workspace so workspace-local tools resolve."
  def port_env(workspace) do
    parent = System.get_env("PATH") || ""
    [{~c"PATH", String.to_charlist(Enum.join([workspace, parent], ":"))}]
  end

  @doc """
  Best-effort port + OS-process termination. `Port.close/1` alone only
  sends SIGTERM, which a busy-loop script ignores until the next
  scheduler tick — leaving an orphan pegging CPU while the BEAM has
  released the port. Send SIGKILL first when the port is still alive.
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
