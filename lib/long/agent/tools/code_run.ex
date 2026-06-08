defmodule Long.Agent.Tools.CodeRun do
  @moduledoc """
  Port of `do_code_run`. Executes a Python or Bash snippet, streaming stdout
  back to the agent loop as it appears, and killing the child on timeout or
  loop shutdown.

  - `:python` — writes the snippet to a temp file under
    `Long.Agent.PythonEnv.root/0` and runs it via `uv run python -X utf8
    -u <file>`. The workspace is a uv-managed project; the agent can
    install missing libraries on demand by running
    `code_run(type: "bash", code: "uv add <pkg>")`.
  - `:bash` / `:shell` / `:sh` — runs `bash -c <code>`. `cwd` defaults to
    the same workspace so `uv add` / `uv pip install` Just Work.
  - `:powershell` — only supported on Windows; on other OSes returns an error.
  """

  @behaviour Long.Agent.Tool

  alias Long.Agent.{PythonEnv, PythonRunner, StepOutcome, ToolContext}

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
        Execute a Python or shell snippet.

        Python runs under a uv-managed workspace (`uv run python …`). Bare `python` /
        `python3` in bash also route through the same uv venv (workspace `.venv/bin`
        is prepended to PATH), so heredocs and one-liners work without prefixing.

        Python stdlib is rich — reach for it first before installing anything:
          - http: `urllib.request` / `http.client`
          - html / xml: `html.parser` / `xml.etree.ElementTree`
          - json / dates / paths: `json` / `datetime` / `pathlib`
          - shell-out / threads: `subprocess` / `threading` / `concurrent.futures`
          - data: `csv` / `sqlite3` / `re` / `collections`

        If you need an external package (e.g. `requests`, `beautifulsoup4`,
        `pandas`), install it persistently into the workspace via bash:
          `code_run(type="bash", code="uv add <package>")`
        then call Python. Dependencies stick across calls. Inspect what's already
        installed with `uv tree` or by reading `pyproject.toml`.

        For "just GET a URL and look at the content", prefer the `http_fetch` tool —
        it's a single round-trip with no Python or browser needed.

        Use `web_scan` / `web_execute_js` only when you need a real browser (Chrome
        running with --remote-debugging-port=9222).
        """,
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
            "cwd" => %{
              "type" => "string",
              "description" =>
                "Relative to the uv workspace root. Leave blank to run in the workspace itself."
            }
          },
          "required" => ["code"]
        }
      }
    }
  end

  @impl true
  def run(args, %ToolContext{cwd: base_cwd, tool_count: tool_count}) do
    code = args["code"] || args["script"]
    code_type = PythonRunner.normalize_type(args["type"] || "python")
    timeout = (args["timeout"] || @default_timeout_seconds) * 1000
    max_bytes = div(@default_max_output_bytes, max(1, tool_count))

    if is_nil(code) or code == "" do
      [
        {:output, Long.Copy.t("tool.code_empty") <> "\n"},
        {:outcome, StepOutcome.cont(%{"status" => "error", "msg" => "code missing"})}
      ]
    else
      {:ok, workspace} = PythonEnv.ensure!(base_cwd)
      cwd = workspace |> Path.join(args["cwd"] || "./") |> Path.expand()
      File.mkdir_p!(cwd)
      execute(code, code_type, timeout, workspace, cwd, max_bytes)
    end
  end

  defp execute(code, type, timeout, workspace, cwd, max_bytes) do
    case PythonRunner.build_command(code, type, cwd) do
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
            {:env, PythonRunner.port_env(workspace)},
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
          PythonRunner.kill_port(port)
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
            "stdout" => PythonRunner.truncate(body, s.max_bytes)
          })

        {[{:output, "[Status] #{icon} exit=#{status}\n"}, {:outcome, outcome}],
         %{s | done?: true}}
    after
      max(0, remaining) ->
        PythonRunner.kill_port(port)
        body = s.collected |> Enum.reverse() |> IO.iodata_to_binary()

        outcome =
          StepOutcome.cont(%{
            "status" => "error",
            "exit_code" => nil,
            "stdout" => PythonRunner.truncate(body, s.max_bytes),
            "msg" => "timeout after #{div(s.timeout, 1000)}s"
          })

        {[{:output, "[Timeout]\n"}, {:outcome, outcome}], %{s | done?: true}}
    end
  end

  defp port_close(%{port: port, cleanup: cleanup}) do
    PythonRunner.kill_port(port)
    cleanup.()
  end
end
