defmodule Long.Jido.Tools.CodeRun do
  @moduledoc """
  Execute a code snippet and collect its output. Code runs on **Deno**
  (the default — sandboxed to the caller's per-member workspace) or
  **bash** (shell / system commands). There is no Python backend.

  Collapses streamed output into a final `{:ok, %{stdout, …}}` return —
  Jido.Action has no streaming contract in v2.1.
  """

  use Jido.Action,
    name: "code_run",
    description:
      "Execute code in your personal sandbox. Default engine is Deno " <>
        "(TypeScript/JavaScript): it runs in a per-member workspace with filesystem " <>
        "access limited to that directory plus network — a safe multi-user sandbox. " <>
        "Use type=\"bash\" for shell / system commands (dates, file ops). For " <>
        "computation, write TS/JS and let it run on Deno (the default). " <>
        "The sandbox has network and can import ANY package from esm.sh / npm, so you " <>
        "can read or convert ANY file type — pick a fitting parser (mammoth for .docx, " <>
        "unpdf for .pdf, JSZip for ZIP-based Office files) or decode the bytes yourself; " <>
        "for an unfamiliar format, find a suitable npm library and just try it before " <>
        "giving up. The only limit: NO subprocess (no python / libreoffice / bash / " <>
        "Deno.Command / child_process). " <>
        "TO CALL AN LLM from a script: POST to Deno.env.get(\"LONG_LLM_URL\") with header " <>
        "\"x-llm-token: \" + Deno.env.get(\"LONG_LLM_TOKEN\") and JSON body " <>
        "{prompt, context}. context=\"new\" is a blank one-shot; context=\"current\" " <>
        "reasons with the user's memory + recent chat (read-only — nothing is written " <>
        "back to the conversation). Response is {text}. No API key needed.",
    category: "code",
    tags: ["deno", "javascript", "typescript", "bash"],
    vsn: "3.0.0",
    schema:
      Zoi.object(%{
        code:
          Zoi.string(description: "Code snippet to execute inline (TS/JS for Deno, or shell for bash)")
          |> Zoi.optional(),
        path:
          Zoi.string(
            description:
              "Run an existing .ts/.js file (relative to your workspace root) on Deno, " <>
                "sandboxed. Use instead of `code` to execute a saved/companion script."
          )
          |> Zoi.optional(),
        type:
          Zoi.string(description: "deno (default, TS/JS) | bash | js | ts")
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

  alias Long.Agent.{CodeRunner, DenoEnv, LLMBridge}
  alias Long.Jido.Tools.Format

  @default_max_output_bytes 10_000

  @impl true
  def run(params, ctx) do
    code_type = CodeRunner.normalize_type(params[:type] || "deno")
    timeout_ms = (params[:timeout] || 60) * 1000
    max_bytes = ctx[:max_output_bytes] || @default_max_output_bytes

    {:ok, workspace} = DenoEnv.ensure!(member_base(ctx))
    cwd = DenoEnv.confine(workspace, params[:cwd])
    File.mkdir_p!(cwd)
    # Per-run LLM token so the script can call the loopback /internal/llm.
    extra_env = LLMBridge.deno_env(ctx[:session_id])
    execute(build(params, code_type, workspace, cwd), workspace, cwd, timeout_ms, max_bytes, extra_env)
  end

  # The caller's personal workspace dir (members/<id>/), or — for an unbound
  # / web-chat session with no group member — an isolated unbound/<sid>/.
  defp member_base(ctx) do
    DenoEnv.session_workspace(ctx[:workspace_root], Format.member_id_for_session(ctx), ctx[:session_id])
  end

  # `path` → run a saved .ts/.js file on Deno (sandboxed). Otherwise run the
  # inline `code` snippet. The path is confined to the member workspace.
  defp build(%{path: path}, _type, workspace, cwd) when is_binary(path) and path != "" do
    target = DenoEnv.confine(workspace, path)

    if File.regular?(target),
      do: CodeRunner.build_deno_file(target, cwd),
      else: {:error, "no such file in your workspace: #{path}"}
  end

  defp build(params, type, _workspace, cwd) do
    CodeRunner.build_command(params[:code] || "", type, cwd)
  end

  defp execute({:error, msg}, _workspace, _cwd, _timeout, _max_bytes, _extra_env) do
    {:ok, %{status: "error", exit_code: nil, stdout: "", msg: msg}}
  end

  defp execute({:ok, exe, args, cleanup}, workspace, cwd, timeout, max_bytes, extra_env) do
    result = run_port(exe, args, workspace, cwd, timeout, max_bytes, extra_env)
    cleanup.()
    {:ok, result}
  end

  defp run_port(exe, args, workspace, cwd, timeout, max_bytes, extra_env) do
    port =
      Port.open({:spawn_executable, System.find_executable(exe) || exe}, [
        :exit_status,
        :binary,
        :stderr_to_stdout,
        {:cd, cwd},
        {:args, args},
        {:env, CodeRunner.port_env(workspace) ++ extra_env},
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
          CodeRunner.kill_port(port)
          body = [chunk | acc] |> Enum.reverse() |> IO.iodata_to_binary()

          %{
            status: "error",
            exit_code: nil,
            stdout: CodeRunner.truncate(body, max_bytes),
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
          stdout: CodeRunner.truncate(body, max_bytes)
        }
    after
      remaining ->
        CodeRunner.kill_port(port)
        body = acc |> Enum.reverse() |> IO.iodata_to_binary()

        %{
          status: "error",
          exit_code: nil,
          stdout: CodeRunner.truncate(body, max_bytes),
          msg: "timeout after #{div(timeout, 1000)}s"
        }
    end
  end
end
