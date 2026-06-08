defmodule Long.Jido.Tools.CodeRun do
  @moduledoc """
  Jido.Action port of `Long.Agent.Tools.CodeRun`. Reuses the uv-managed
  workspace from `Long.Agent.PythonEnv` and the same port plumbing from
  `Long.Agent.PythonRunner`, but collapses the streamed output into a
  final `{:ok, %{stdout, …}}` return — Jido.Action doesn't have a
  streaming contract in v2.1. Phase B v3 can switch to directives if
  we want real-time stdout back.
  """

  use Jido.Action,
    name: "code_run",
    description:
      "Execute code in your personal sandbox. Default engine is Deno " <>
        "(TypeScript/JavaScript): it runs in a per-member workspace with filesystem " <>
        "access limited to that directory plus network — a safe multi-user sandbox. " <>
        "Use type=\"bash\" for a shell snippet. Python is available as an opt-in heavy " <>
        "mode (type=\"python\", uv-managed) for tasks that need the Python package " <>
        "ecosystem; install libs via type=bash, code='uv add <pkg>'.",
    category: "code",
    tags: ["deno", "javascript", "typescript", "bash", "python"],
    vsn: "2.0.0",
    schema:
      Zoi.object(%{
        code: Zoi.string(description: "Code snippet to execute"),
        type:
          Zoi.string(description: "deno (default, TS/JS) | bash | python | js | ts")
          |> Zoi.optional()
          |> Zoi.default("deno"),
        timeout:
          Zoi.integer(description: "Timeout in seconds, default 60")
          |> Zoi.optional()
          |> Zoi.default(60),
        cwd:
          Zoi.string(description: "Relative to your personal workspace root.")
          |> Zoi.optional()
      })

  alias Long.Agent.{DenoEnv, PythonEnv, PythonRunner}
  alias Long.Jido.Tools.Format

  @default_max_output_bytes 10_000

  @impl true
  def run(params, ctx) do
    code = params[:code]
    code_type = PythonRunner.normalize_type(params[:type] || "deno")
    timeout_ms = (params[:timeout] || 60) * 1000
    max_bytes = ctx[:max_output_bytes] || @default_max_output_bytes

    {:ok, workspace} = ensure_workspace(code_type, member_base(ctx))
    cwd = workspace |> Path.join(params[:cwd] || "./") |> Path.expand()
    File.mkdir_p!(cwd)
    execute(code, code_type, timeout_ms, workspace, cwd, max_bytes)
  end

  # The caller's personal workspace dir (members/<id>/), or the shared
  # base for an unbound / web-chat session with no household member.
  defp member_base(ctx) do
    DenoEnv.workspace(ctx[:workspace_root], Format.member_id_for_session(ctx))
  end

  # Python needs its uv project scaffolding written into the dir; Deno and
  # bash just need the directory to exist.
  defp ensure_workspace("python", base), do: PythonEnv.ensure!(base)
  defp ensure_workspace(_other, base), do: DenoEnv.ensure!(base)

  defp execute(code, type, timeout, workspace, cwd, max_bytes) do
    case PythonRunner.build_command(code, type, cwd) do
      {:error, msg} ->
        {:ok, %{status: "error", exit_code: nil, stdout: "", msg: msg}}

      {:ok, exe, args, cleanup} ->
        result = run_port(exe, args, workspace, cwd, timeout, max_bytes)
        cleanup.()
        {:ok, result}
    end
  end

  defp run_port(exe, args, workspace, cwd, timeout, max_bytes) do
    port =
      Port.open({:spawn_executable, System.find_executable(exe) || exe}, [
        :exit_status,
        :binary,
        :stderr_to_stdout,
        {:cd, cwd},
        {:args, args},
        {:env, PythonRunner.port_env(workspace)},
        :hide
      ])

    deadline = System.monotonic_time(:millisecond) + timeout
    collect(port, deadline, timeout, [], 0, max_bytes)
  end

  defp collect(port, deadline, timeout, acc, size, max_bytes) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, chunk}} ->
        if size + byte_size(chunk) > max_bytes do
          PythonRunner.kill_port(port)
          body = [chunk | acc] |> Enum.reverse() |> IO.iodata_to_binary()

          %{
            status: "error",
            exit_code: nil,
            stdout: PythonRunner.truncate(body, max_bytes),
            msg: "output exceeded #{max_bytes} bytes"
          }
        else
          collect(port, deadline, timeout, [chunk | acc], size + byte_size(chunk), max_bytes)
        end

      {^port, {:exit_status, exit_code}} ->
        body = acc |> Enum.reverse() |> IO.iodata_to_binary()

        %{
          status: if(exit_code == 0, do: "success", else: "error"),
          exit_code: exit_code,
          stdout: PythonRunner.truncate(body, max_bytes)
        }
    after
      remaining ->
        PythonRunner.kill_port(port)
        body = acc |> Enum.reverse() |> IO.iodata_to_binary()

        %{
          status: "error",
          exit_code: nil,
          stdout: PythonRunner.truncate(body, max_bytes),
          msg: "timeout after #{div(timeout, 1000)}s"
        }
    end
  end
end
