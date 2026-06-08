defmodule Long.Agent.Tools.CodeRun do
  @moduledoc """
  Executes a Deno or Bash snippet, streaming stdout back to the agent
  loop as it appears, and killing the child on timeout or loop shutdown.

  - `:deno` (default) — writes the snippet to a temp `.ts` and runs it
    sandboxed to the caller's per-member workspace (read/write limited to
    that dir, plus network).
  - `:bash` / `:shell` / `:sh` — runs `bash -c <code>` for shell ops.
  - `:powershell` — Windows only.

  No Python backend — code execution is Deno-only (plus bash for shell).
  """

  @behaviour Long.Agent.Tool

  alias Long.Agent.{CodeRunner, DenoEnv, StepOutcome, ToolContext}

  @default_timeout_seconds 60
  @default_max_output_bytes 10_000

  @impl true
  def name, do: "code_run"

  @impl true
  def schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => name(),
        "description" => """
        Execute a Deno (TypeScript/JavaScript) or shell snippet.

        Default engine is Deno: code runs in your per-member workspace,
        sandboxed to that directory plus network. Use type="bash" for
        shell / system commands (dates, file ops, running a tool).

        For "just GET a URL and look at the content", prefer the `http_fetch`
        tool. Use `web_scan` / `web_execute_js` when you need a real browser.
        """,
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "code" => %{"type" => "string"},
            "type" => %{
              "type" => "string",
              "enum" => ["deno", "bash", "js", "ts", "shell", "sh"],
              "default" => "deno"
            },
            "timeout" => %{"type" => "integer", "default" => @default_timeout_seconds},
            "cwd" => %{
              "type" => "string",
              "description" =>
                "Relative to your workspace root. Leave blank to run in the workspace itself."
            }
          },
          "required" => ["code"]
        }
      }
    }
  end

  @impl true
  def run(args, %ToolContext{tool_count: tool_count} = ctx) do
    code = args["code"] || args["script"]
    code_type = CodeRunner.normalize_type(args["type"] || "deno")
    timeout = (args["timeout"] || @default_timeout_seconds) * 1000
    max_bytes = div(@default_max_output_bytes, max(1, tool_count))

    if is_nil(code) or code == "" do
      [
        {:output, Long.Copy.t("tool.code_empty") <> "\n"},
        {:outcome, StepOutcome.cont(%{"status" => "error", "msg" => "code missing"})}
      ]
    else
      member_id = ctx.session_id && Long.Agent.member_id_for_session(ctx.session_id)
      base = DenoEnv.session_workspace(ctx.cwd, member_id, ctx.session_id)
      {:ok, workspace} = DenoEnv.ensure!(base)
      cwd = DenoEnv.confine(workspace, args["cwd"])
      File.mkdir_p!(cwd)
      execute(code, code_type, timeout, workspace, cwd, max_bytes)
    end
  end

  defp execute(code, type, timeout, workspace, cwd, max_bytes) do
    case CodeRunner.build_command(code, type, cwd) do
      {:error, msg} ->
        [
          {:output, "[Status] ❌ #{msg}\n"},
          {:outcome, StepOutcome.cont(%{"status" => "error", "msg" => msg})}
        ]

      {:ok, exe, args, cleanup} ->
        Stream.concat([
          [{:output, "[Action] Running #{type} in #{Path.basename(cwd)}: #{preview(code)}\n"}],
          run_port(exe, args, workspace, cwd, timeout, max_bytes, cleanup)
        ])
    end
  end

  defp preview(code) do
    head = code |> String.replace(~r/\s+/, " ") |> String.slice(0, 60)
    if String.length(code) > 60, do: head <> "...", else: head
  end

  defp run_port(exe, args, workspace, cwd, timeout, max_bytes, cleanup) do
    Stream.resource(
      fn ->
        port =
          Port.open({:spawn_executable, System.find_executable(exe) || exe}, [
            :exit_status,
            :binary,
            :stderr_to_stdout,
            {:cd, cwd},
            {:args, args},
            {:env, CodeRunner.port_env(workspace)},
            :hide
          ])

        deadline = System.monotonic_time(:millisecond) + timeout

        %{
          port: port,
          deadline: deadline,
          timeout: timeout,
          collected: [],
          collected_size: 0,
          max_bytes: max_bytes,
          cleanup: cleanup,
          done?: false
        }
      end,
      &port_next/1,
      &port_close/1
    )
  end

  defp port_next(%{done?: true} = s), do: {:halt, s}

  defp port_next(%{port: port, deadline: deadline} = s) do
    remaining = deadline - System.monotonic_time(:millisecond)

    receive do
      {^port, {:data, chunk}} ->
        collected = [chunk | s.collected]
        collected_size = s.collected_size + byte_size(chunk)
        truncated? = collected_size > s.max_bytes

        events = [{:output, chunk}]
        events = if truncated?, do: events ++ [{:output, "\n[Truncated]\n"}], else: events

        if truncated? do
          CodeRunner.kill_port(port)
          {events, %{s | done?: true}}
        else
          {events, %{s | collected: collected, collected_size: collected_size}}
        end

      {^port, {:exit_status, status}} ->
        body = s.collected |> Enum.reverse() |> IO.iodata_to_binary()
        icon = if status == 0, do: "✅", else: "❌"

        outcome =
          StepOutcome.cont(%{
            "status" => if(status == 0, do: "success", else: "error"),
            "exit_code" => status,
            "stdout" => CodeRunner.truncate(body, s.max_bytes)
          })

        {[{:output, "[Status] #{icon} exit=#{status}\n"}, {:outcome, outcome}],
         %{s | done?: true}}
    after
      max(0, remaining) ->
        CodeRunner.kill_port(port)
        body = s.collected |> Enum.reverse() |> IO.iodata_to_binary()

        outcome =
          StepOutcome.cont(%{
            "status" => "error",
            "exit_code" => nil,
            "stdout" => CodeRunner.truncate(body, s.max_bytes),
            "msg" => "timeout after #{div(s.timeout, 1000)}s"
          })

        {[{:output, "[Timeout]\n"}, {:outcome, outcome}], %{s | done?: true}}
    end
  end

  defp port_close(%{port: port, cleanup: cleanup}) do
    CodeRunner.kill_port(port)
    cleanup.()
  end
end
