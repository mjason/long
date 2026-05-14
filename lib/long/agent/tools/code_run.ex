defmodule Long.Agent.Tools.CodeRun do
  @moduledoc """
  Port of `do_code_run`. Executes a Python or Bash snippet, streaming stdout
  back to the agent loop as it appears, and killing the child on timeout or
  loop shutdown.

  - `:python` — writes the snippet to a temp file and runs
    `python3 -X utf8 -u <file>`
  - `:bash` / `:shell` / `:sh` — runs `bash -c <code>`
  - `:powershell` — only supported on Windows; on other OSes returns an error
  """

  @behaviour Long.Agent.Tool

  alias Long.Agent.{StepOutcome, ToolContext}

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
        "description" =>
          "Execute a Python or shell snippet. Prefer Python for non-trivial work; use bash for one-liners.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "code" => %{"type" => "string"},
            "type" => %{
              "type" => "string",
              "enum" => ["python", "bash", "shell", "sh"],
              "default" => "python"
            },
            "timeout" => %{"type" => "integer", "default" => @default_timeout_seconds},
            "cwd" => %{"type" => "string", "description" => "Relative to the agent cwd."}
          },
          "required" => ["code"]
        }
      }
    }
  end

  @impl true
  def run(args, %ToolContext{cwd: base_cwd, tool_count: tool_count}) do
    code = args["code"] || args["script"]
    code_type = normalize_type(args["type"] || "python")
    timeout = (args["timeout"] || @default_timeout_seconds) * 1000
    cwd = base_cwd |> Path.join(args["cwd"] || "./") |> Path.expand()
    max_bytes = div(@default_max_output_bytes, max(1, tool_count))

    cond do
      is_nil(code) or code == "" ->
        [
          {:output, "[Status] ❌ 失败: code 为空\n"},
          {:outcome, StepOutcome.cont(%{"status" => "error", "msg" => "code missing"})}
        ]

      not File.dir?(cwd) ->
        File.mkdir_p!(cwd)
        execute(code, code_type, timeout, cwd, max_bytes)

      true ->
        execute(code, code_type, timeout, cwd, max_bytes)
    end
  end

  defp normalize_type("py"), do: "python"
  defp normalize_type("shell"), do: "bash"
  defp normalize_type("sh"), do: "bash"
  defp normalize_type(t), do: t

  defp execute(code, type, timeout, cwd, max_bytes) do
    case build_command(code, type, cwd) do
      {:error, msg} ->
        [
          {:output, "[Status] ❌ #{msg}\n"},
          {:outcome, StepOutcome.cont(%{"status" => "error", "msg" => msg})}
        ]

      {:ok, exe, args, cleanup} ->
        preview = preview(code)

        Stream.concat([
          [{:output, "[Action] Running #{type} in #{Path.basename(cwd)}: #{preview}\n"}],
          run_port(exe, args, cwd, timeout, max_bytes, cleanup)
        ])
    end
  end

  defp preview(code) do
    head =
      code
      |> String.replace(~r/\s+/, " ")
      |> String.slice(0, 60)

    if String.length(code) > 60, do: head <> "...", else: head
  end

  defp build_command(code, "python", cwd) do
    tmp = Path.join(cwd, ".ai_#{System.unique_integer([:positive])}.py")
    File.write!(tmp, code)
    {:ok, python_bin(), ["-X", "utf8", "-u", tmp], fn -> File.rm(tmp) end}
  end

  defp build_command(code, "bash", _cwd), do: {:ok, "bash", ["-c", code], fn -> :ok end}

  defp build_command(_code, "powershell", _cwd) do
    if match?({:win32, _}, :os.type()) do
      {:ok, "powershell", ["-NoProfile", "-NonInteractive", "-Command"], fn -> :ok end}
    else
      {:error, "powershell only supported on Windows"}
    end
  end

  defp build_command(_code, type, _cwd), do: {:error, "unsupported code_type: #{type}"}

  defp python_bin do
    System.find_executable("python3") || System.find_executable("python") || "python3"
  end

  defp run_port(exe, args, cwd, timeout, max_bytes, cleanup) do
    Stream.resource(
      fn ->
        port =
          Port.open({:spawn_executable, System.find_executable(exe) || exe}, [
            :exit_status,
            :binary,
            :stderr_to_stdout,
            {:cd, cwd},
            {:args, args},
            :hide
          ])

        deadline = System.monotonic_time(:millisecond) + timeout

        %{
          port: port,
          deadline: deadline,
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
          kill_port(port)
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
            "stdout" => truncate(body, s.max_bytes)
          })

        {[{:output, "[Status] #{icon} exit=#{status}\n"}, {:outcome, outcome}],
         %{s | done?: true}}
    after
      max(0, remaining) ->
        kill_port(port)
        body = s.collected |> Enum.reverse() |> IO.iodata_to_binary()

        outcome =
          StepOutcome.cont(%{
            "status" => "error",
            "exit_code" => nil,
            "stdout" => truncate(body, s.max_bytes),
            "msg" =>
              "timeout after #{div(deadline + timeout_now() - System.monotonic_time(:millisecond), 1000)}s"
          })

        {[{:output, "[Timeout]\n"}, {:outcome, outcome}], %{s | done?: true}}
    end
  end

  defp port_close(%{port: port, cleanup: cleanup}) do
    kill_port(port)
    cleanup.()
  end

  defp kill_port(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp timeout_now, do: 0

  defp truncate(s, max) when byte_size(s) > max do
    binary_part(s, 0, div(max, 2)) <>
      "\n\n[omitted long output]\n\n" <> binary_part(s, byte_size(s) - div(max, 2), div(max, 2))
  end

  defp truncate(s, _), do: s
end
