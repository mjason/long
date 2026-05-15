defmodule TapBackend do
  @moduledoc false
  @behaviour Long.Agent.LLM.Backend

  defstruct [:inner, :recorder]

  @impl true
  def stream_chat(%__MODULE__{inner: %mod{} = inner, recorder: rec}, messages, opts) do
    rec.(opts)
    mod.stream_chat(inner, messages, opts)
  end
end

defmodule Long.Agent.MemoryTest do
  use Long.DataCase, async: false

  alias Long.Agent
  alias Long.Agent.{Loop, Memory, StepOutcome, ToolContext}
  alias Long.Agent.LLM.Backend.Scripted
  alias Long.Agent.LLM.Response

  alias Long.Agent.Tools.{
    MemoryUpsert,
    StartLongTermUpdate
  }

  describe "build_system_prompt/2" do
    test "returns empty when no session_id and no memory" do
      assert "" == Memory.build_system_prompt(nil)
    end

    test "includes L2 sections grouped by scope, insight first" do
      {:ok, _} = Agent.put_global_memory(%{scope: :general, key: "host", value: "example.com"})
      {:ok, _} = Agent.put_global_memory(%{scope: :insight, key: "tone", value: "terse"})

      prompt = Memory.build_system_prompt(nil)
      assert prompt =~ "[Global memory — L2 · insight]"
      assert prompt =~ "[Global memory — L2 · general]"
      # insight appears before general
      assert :binary.match(prompt, "insight") |> elem(0) <
               :binary.match(prompt, "general") |> elem(0)
    end

    test "includes L1 working checkpoint when session has one" do
      {:ok, sess} = Agent.start_session(%{title: "s"})
      {:ok, _} = Agent.upsert_checkpoint(%{session_id: sess.id, key_info: "remember: foo"})

      prompt = Memory.build_system_prompt(sess.id)
      assert prompt =~ "[Working memory — L1]"
      assert prompt =~ "remember: foo"
    end

    test "honors :prefix option" do
      prompt = Memory.build_system_prompt(nil, prefix: "## Goal\nbe helpful.")

      assert prompt =~ "## Goal\nbe helpful."
    end
  end

  describe "archive_session/2" do
    test "snapshots messages + checkpoint into a SessionArchive row" do
      {:ok, sess} = Agent.start_session(%{title: "to-archive"})

      {:ok, _} = Agent.append_message(%{session_id: sess.id, role: :user, content: "hi", turn: 1})

      {:ok, _} =
        Agent.append_message(%{session_id: sess.id, role: :assistant, content: "hello", turn: 1})

      {:ok, _} = Agent.upsert_checkpoint(%{session_id: sess.id, key_info: "key=42"})

      assert {:ok, arch} = Memory.archive_session(sess.id)
      assert arch.original_session_id == sess.id
      assert arch.summary =~ "hello"
      assert arch.payload["checkpoint"] == "key=42"
      assert length(arch.payload["messages"]) == 2
    end

    test "passes through a custom summarizer" do
      {:ok, sess} = Agent.start_session(%{title: "custom"})
      {:ok, _} = Agent.append_message(%{session_id: sess.id, role: :user, content: "go", turn: 1})

      summarizer = fn _ -> {:ok, %{title: "T", summary: "S", insights: "I"}} end
      assert {:ok, arch} = Memory.archive_session(sess.id, summary_fn: summarizer)
      assert arch.title == "T"
      assert arch.summary == "S"
      assert arch.insights == "I"
    end
  end

  describe "MemoryUpsert tool" do
    test "creates and then updates an L2 entry by (scope, key)" do
      [_, {:outcome, %StepOutcome{data: %{"status" => "success"}}}] =
        MemoryUpsert.run(
          %{"scope" => "general", "key" => "host", "value" => "v1"},
          %ToolContext{}
        )
        |> Enum.to_list()

      [_, {:outcome, %StepOutcome{data: %{"status" => "success"}}}] =
        MemoryUpsert.run(
          %{"scope" => "general", "key" => "host", "value" => "v2"},
          %ToolContext{}
        )
        |> Enum.to_list()

      {:ok, rows} = Agent.list_global_memory()
      assert length(rows) == 1
      assert hd(rows).value == "v2"
    end

    test "rejects blank key" do
      [_, {:outcome, %StepOutcome{data: %{"status" => "error"}}}] =
        MemoryUpsert.run(%{"scope" => "general", "key" => "", "value" => "x"}, %ToolContext{})
        |> Enum.to_list()
    end
  end

  describe "StartLongTermUpdate tool" do
    test "skips when session_id is nil" do
      [_, {:outcome, %StepOutcome{data: %{"status" => "skipped"}}}] =
        StartLongTermUpdate.run(%{}, %ToolContext{}) |> Enum.to_list()
    end

    test "archives when session_id present" do
      {:ok, sess} = Agent.start_session(%{title: "lt"})
      {:ok, _} = Agent.append_message(%{session_id: sess.id, role: :user, content: "k", turn: 1})

      [_, {:outcome, %StepOutcome{data: %{"status" => "success", "archive_id" => _}}}] =
        StartLongTermUpdate.run(%{}, %ToolContext{session_id: sess.id}) |> Enum.to_list()

      assert {:ok, [_]} = Agent.list_archives()
    end
  end

  describe "Loop auto-composes system prompt from memory" do
    setup do
      {:ok, sess} = Agent.start_session(%{title: "loop-mem"})
      {:ok, _} = Agent.upsert_checkpoint(%{session_id: sess.id, key_info: "must-remember"})

      {:ok, _} =
        Agent.put_global_memory(%{scope: :insight, key: "style", value: "concise"})

      {:ok, sess: sess}
    end

    test "the system prompt seen by the backend contains L1+L2", %{sess: sess} do
      # Capture the messages payload by sending it through a backend that
      # records what it receives.
      backend =
        Scripted.start([
          Response.from_blocks([%{type: :text, text: "ok"}])
        ])

      # Use a custom tap backend that forwards to scripted but records system
      this = self()

      tap_backend = %TapBackend{
        inner: backend,
        recorder: fn opts -> send(this, {:system, opts[:system]}) end
      }

      events =
        Loop.run(backend: tap_backend, user: "hi", session_id: sess.id)
        |> Enum.to_list()

      assert {:done, %{reason: :no_tool_call}} = List.last(events)

      assert_received {:system, system}
      assert system =~ "must-remember"
      assert system =~ "concise"

      Scripted.stop(backend)
    end
  end
end
