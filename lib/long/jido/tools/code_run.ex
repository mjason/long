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
      "Execute a Python or shell snippet. Python runs under a uv-managed workspace " <>
        "(uv run python). Bare `python`/`python3` also work via PATH shims. If a " <>
        "library is missing, first call this with type=bash, code='uv add <pkg>', " <>
        "then call Python.",
    category: "code",
    tags: ["python", "bash", "shell"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        code: Zoi.string(description: "Code snippet to execute"),
        type:
          Zoi.string(description: "python | bash | shell | sh")
          |> Zoi.optional()
          |> Zoi.default("python"),
        timeout:
          Zoi.integer(description: "Timeout in seconds, default 60")
          |> Zoi.optional()
          |> Zoi.default(60),
        cwd:
          Zoi.string(description: "Relative to the uv workspace root.")
          |> Zoi.optional()
      })

  alias Long.Agent.{PythonEnv, PythonRunner}

  @default_max_output_bytes 10_000

  @impl true
  def run(params, ctx) do
    code = params[:code]
    code_type = PythonRunner.normalize_type(params[:type] || "python")
    timeout_ms = (params[:timeout] || 60) * 1000
    max_bytes = ctx[:max_output_bytes] || @default_max_output_bytes

    case PythonEnv.ensure!(ctx[:workspace_root]) do
      {:ok, workspace} ->
        cwd = workspace |> Path.join(params[:cwd] || "./") |> Path.expand()
        File.mkdir_p!(cwd)
        execute(code, code_type, timeout_ms, workspace, cwd, max_bytes)
    end
  end

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
