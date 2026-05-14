defmodule Long.Agent.LoopTest do
  use Long.DataCase, async: false

  alias Long.Agent
  alias Long.Agent.{Loop, StepOutcome, ToolContext}
  alias Long.Agent.LLM.Backend.Scripted
  alias Long.Agent.LLM.Response

  alias Long.Agent.Tools.{
    AskUser,
    CodeRun,
    FileRead,
    FileWrite,
    FilePatch,
    UpdateWorkingCheckpoint
  }

  setup do
    cwd = Path.join(System.tmp_dir!(), "long_loop_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf(cwd) end)
    {:ok, cwd: cwd}
  end

  # ── Tool-level tests ──────────────────────────────────────────────────────

  describe "FileRead / FileWrite / FilePatch" do
    test "write then read with line numbers", %{cwd: cwd} do
      ctx = %ToolContext{cwd: cwd}

      [{:output, _}, {:outcome, %StepOutcome{data: %{"status" => "success"}}}] =
        FileWrite.run(%{"path" => "hello.txt", "content" => "line1\nline2\nline3"}, ctx)
        |> Enum.to_list()

      assert [
               {:output, _},
               {:outcome,
                %StepOutcome{
                  data: %{"status" => "success", "content" => body, "total_lines" => 3}
                }}
             ] = FileRead.run(%{"path" => "hello.txt"}, ctx) |> Enum.to_list()

      assert body =~ "1|line1"
      assert body =~ "3|line3"
    end

    test "FileRead grep returns matched neighbourhood", %{cwd: cwd} do
      File.write!(Path.join(cwd, "grep.txt"), Enum.map_join(1..20, "\n", &"line #{&1}"))
      ctx = %ToolContext{cwd: cwd}

      assert [
               {:output, _},
               {:outcome, %StepOutcome{data: %{"content" => body}}}
             ] =
               FileRead.run(%{"path" => "grep.txt", "keyword" => "line 7", "count" => 5}, ctx)
               |> Enum.to_list()

      assert body =~ "line 7"
    end

    test "FilePatch single anchor success and multi-anchor error", %{cwd: cwd} do
      path = Path.join(cwd, "p.txt")
      File.write!(path, "alpha\nbravo\nalpha\n")
      ctx = %ToolContext{cwd: cwd}

      # multiple anchors → error
      assert [
               {:output, _},
               {:outcome, %StepOutcome{data: %{"status" => "error", "msg" => msg}}}
             ] =
               FilePatch.run(
                 %{"path" => "p.txt", "old_content" => "alpha", "new_content" => "ALPHA"},
                 ctx
               )
               |> Enum.to_list()

      assert msg =~ "matches 2 sites"

      # unique anchor → success
      assert [
               {:output, _},
               {:outcome, %StepOutcome{data: %{"status" => "success"}}}
             ] =
               FilePatch.run(
                 %{"path" => "p.txt", "old_content" => "bravo", "new_content" => "BRAVO"},
                 ctx
               )
               |> Enum.to_list()

      assert File.read!(path) == "alpha\nBRAVO\nalpha\n"
    end
  end

  describe "CodeRun" do
    test "bash echo streams stdout and reports exit_code 0", %{cwd: cwd} do
      ctx = %ToolContext{cwd: cwd, tool_count: 1}

      events =
        CodeRun.run(%{"type" => "bash", "code" => "printf 'hi from bash'"}, ctx)
        |> Enum.to_list()

      outputs = for {:output, t} <- events, do: t
      assert Enum.any?(outputs, &(&1 =~ "hi from bash"))

      assert [{:outcome, %StepOutcome{data: %{"exit_code" => 0, "stdout" => stdout}}}] =
               Enum.filter(events, &match?({:outcome, _}, &1))

      assert stdout =~ "hi from bash"
    end

    test "non-zero exit propagates", %{cwd: cwd} do
      ctx = %ToolContext{cwd: cwd, tool_count: 1}

      events =
        CodeRun.run(%{"type" => "bash", "code" => "exit 7"}, ctx)
        |> Enum.to_list()

      assert [{:outcome, %StepOutcome{data: %{"exit_code" => 7, "status" => "error"}}}] =
               Enum.filter(events, &match?({:outcome, _}, &1))
    end
  end

  describe "UpdateWorkingCheckpoint" do
    test "persists when session_id is set" do
      {:ok, sess} = Agent.start_session(%{title: "t"})
      ctx = %ToolContext{session_id: sess.id, cwd: "/tmp"}

      [_, {:outcome, %StepOutcome{data: %{"status" => "success", "stored" => :persisted}}}] =
        UpdateWorkingCheckpoint.run(%{"key_info" => "remember this"}, ctx) |> Enum.to_list()

      assert {:ok, %{key_info: "remember this"}} = Agent.get_checkpoint(sess.id)
    end

    test "ephemeral when session_id is nil" do
      ctx = %ToolContext{session_id: nil, cwd: "/tmp"}

      [_, {:outcome, %StepOutcome{data: %{"stored" => :ephemeral}}}] =
        UpdateWorkingCheckpoint.run(%{"key_info" => "x"}, ctx) |> Enum.to_list()
    end
  end

  describe "AskUser" do
    test "emits should_exit? outcome" do
      [_, {:outcome, %StepOutcome{should_exit?: true, data: %{"question" => "Continue?"}}}] =
        AskUser.run(%{"question" => "Continue?", "candidates" => ["yes", "no"]}, %ToolContext{})
        |> Enum.to_list()
    end
  end

  # ── Loop integration tests ───────────────────────────────────────────────

  describe "Loop integration" do
    test "two turns: read a file then summarize", %{cwd: cwd} do
      File.write!(Path.join(cwd, "doc.txt"), "secret = 42")

      backend =
        Scripted.start([
          # Turn 1: ask to read the file
          Response.from_blocks([
            %{type: :text, text: "Let me read it."},
            %{
              type: :tool_use,
              id: "t1",
              name: "file_read",
              input: %{"path" => "doc.txt", "show_linenos" => false}
            }
          ]),
          # Turn 2: deliver the answer, no further tools
          Response.from_blocks([%{type: :text, text: "The secret is 42."}])
        ])

      events =
        Loop.run(backend: backend, user: "read doc.txt and tell me the secret", cwd: cwd)
        |> Enum.to_list()

      # Two turn_start events fired
      turn_starts = for {:turn_start, n} <- events, do: n
      assert turn_starts == [1, 2]

      # file_read was dispatched on turn 1
      assert Enum.any?(events, fn
               {:tool_start, %{name: "file_read"}} -> true
               _ -> false
             end)

      # Loop terminated with :no_tool_call after turn 2
      assert {:done, %{reason: :no_tool_call}} = List.last(events)

      Scripted.stop(backend)
    end

    test "ask_user halts the loop with :asked_user", %{cwd: cwd} do
      backend =
        Scripted.start([
          Response.from_blocks([
            %{type: :text, text: "I need input."},
            %{
              type: :tool_use,
              id: "t1",
              name: "ask_user",
              input: %{"question" => "Continue?", "candidates" => ["yes", "no"]}
            }
          ])
        ])

      events = Loop.run(backend: backend, user: "go", cwd: cwd) |> Enum.to_list()

      assert Enum.any?(events, fn
               {:ask_user, %{"question" => "Continue?"}} -> true
               _ -> false
             end)

      assert {:done, %{reason: :asked_user}} = List.last(events)
      Scripted.stop(backend)
    end

    test "unknown tool emits an error outcome but loop continues to next turn", %{cwd: cwd} do
      backend =
        Scripted.start([
          Response.from_blocks([
            %{type: :tool_use, id: "tx", name: "no_such_tool", input: %{}}
          ]),
          Response.from_blocks([%{type: :text, text: "Got it."}])
        ])

      events = Loop.run(backend: backend, user: "go", cwd: cwd) |> Enum.to_list()

      tool_done =
        Enum.find(events, fn
          {:tool_done, %{name: "no_such_tool"}} -> true
          _ -> false
        end)

      assert tool_done

      assert {:done, %{reason: :no_tool_call}} = List.last(events)
      Scripted.stop(backend)
    end

    test "max_turns guard fires", %{cwd: cwd} do
      # Backend keeps asking for the same tool forever (we only feed it 5 responses
      # but enforce max_turns=2 to ensure the loop short-circuits)
      backend =
        Scripted.start(
          for _ <- 1..5 do
            Response.from_blocks([
              %{
                type: :tool_use,
                id: "tx",
                name: "update_working_checkpoint",
                input: %{"key_info" => "k"}
              }
            ])
          end
        )

      events =
        Loop.run(backend: backend, user: "go", cwd: cwd, max_turns: 2)
        |> Enum.to_list()

      assert {:done, %{reason: :max_turns, turn: 2}} = List.last(events)
      Scripted.stop(backend)
    end

    test "a crashing tool does not bring down the loop", %{cwd: cwd} do
      defmodule CrashingTool do
        @behaviour Long.Agent.Tool

        def name, do: "crash"

        def schema,
          do: %{
            "type" => "function",
            "function" => %{"name" => name(), "parameters" => %{"type" => "object"}}
          }

        def run(_args, _ctx), do: raise("kaboom — synthetic tool failure")
      end

      backend =
        Scripted.start([
          Response.from_blocks([%{type: :tool_use, id: "x1", name: "crash", input: %{}}]),
          Response.from_blocks([%{type: :text, text: "recovered"}])
        ])

      events =
        Loop.run(
          backend: backend,
          user: "go",
          cwd: cwd,
          tools: [CrashingTool]
        )
        |> Enum.to_list()

      tool_done =
        Enum.find(events, fn
          {:tool_done, %{name: "crash"}} -> true
          _ -> false
        end)

      assert tool_done, "expected the loop to emit :tool_done with an error outcome"
      assert tool_done |> elem(1) |> Map.get(:data) |> Map.get("status") == "error"
      assert {:done, %{reason: :no_tool_call}} = List.last(events)

      Scripted.stop(backend)
    end

    test "code_run + file_read in the same turn", %{cwd: cwd} do
      backend =
        Scripted.start([
          Response.from_blocks([
            %{
              type: :tool_use,
              id: "a",
              name: "code_run",
              input: %{"type" => "bash", "code" => "printf 'one\\ntwo' > out.txt"}
            },
            %{
              type: :tool_use,
              id: "b",
              name: "file_read",
              input: %{"path" => "out.txt", "show_linenos" => false}
            }
          ]),
          Response.from_blocks([%{type: :text, text: "done"}])
        ])

      events = Loop.run(backend: backend, user: "do it", cwd: cwd) |> Enum.to_list()

      # Both tools dispatched on turn 1, with correct index/count
      tool_starts = for {:tool_start, m} <- events, do: m

      assert [
               %{name: "code_run", index: 0, count: 2},
               %{name: "file_read", index: 1, count: 2}
             ] = tool_starts

      assert {:done, %{reason: :no_tool_call}} = List.last(events)
      Scripted.stop(backend)
    end
  end
end
