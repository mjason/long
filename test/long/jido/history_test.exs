defmodule Long.Jido.HistoryTest do
  use Long.DataCase, async: false

  alias Long.Agent
  alias Long.Jido.History

  setup do
    {:ok, session} = Agent.start_session(%{title: "history-test"})
    {:ok, session: session}
  end

  describe "load/2" do
    test "returns [] for empty session", %{session: session} do
      assert History.load(session.id) == []
    end

    test "converts user + assistant rows into ReqLLM messages", %{session: session} do
      {:ok, _} = Agent.append_message(%{session_id: session.id, role: :user, content: "hello", turn: 1})

      {:ok, _} =
        Agent.append_message(%{session_id: session.id, role: :assistant, content: "hi back", turn: 2})

      msgs = History.load(session.id)
      assert length(msgs) == 2

      [%ReqLLM.Message{role: :user}, %ReqLLM.Message{role: :assistant}] = msgs
    end

    test "preserves tool_calls on assistant messages", %{session: session} do
      {:ok, _} =
        Agent.append_message(%{
          session_id: session.id,
          role: :assistant,
          content: "",
          tool_calls: [%{"id" => "call_1", "name" => "http_fetch", "input" => %{"url" => "x"}}],
          turn: 1
        })

      {:ok, _} =
        Agent.append_message(%{
          session_id: session.id,
          role: :user,
          content: "",
          tool_results: [%{"tool_use_id" => "call_1", "content" => "result body"}],
          turn: 2
        })

      [
        %ReqLLM.Message{role: :assistant, tool_calls: [tc]},
        %ReqLLM.Message{role: :tool, tool_call_id: "call_1"}
      ] = History.load(session.id)

      assert tc.id == "call_1"
    end

    test "converts user tool_results into tool messages", %{session: session} do
      {:ok, _} =
        Agent.append_message(%{
          session_id: session.id,
          role: :assistant,
          content: "",
          tool_calls: [%{"id" => "call_1", "name" => "http_fetch", "input" => %{"url" => "x"}}],
          turn: 1
        })

      {:ok, _} =
        Agent.append_message(%{
          session_id: session.id,
          role: :user,
          content: "",
          tool_results: [%{"tool_use_id" => "call_1", "content" => "result body"}],
          turn: 2
        })

      [%ReqLLM.Message{role: :assistant}, %ReqLLM.Message{role: :tool}] = History.load(session.id)
    end

    test "synthesizes placeholder tool_result for orphan tool_call", %{session: session} do
      {:ok, _} =
        Agent.append_message(%{
          session_id: session.id,
          role: :assistant,
          content: "",
          tool_calls: [%{"id" => "call_missing", "name" => "x", "input" => %{}}],
          turn: 1
        })

      {:ok, _} =
        Agent.append_message(%{session_id: session.id, role: :user, content: "next", turn: 2})

      [
        %ReqLLM.Message{role: :assistant, tool_calls: [_]},
        %ReqLLM.Message{role: :tool, tool_call_id: "call_missing"} = synthetic,
        %ReqLLM.Message{role: :user}
      ] = History.load(session.id)

      assert [%{type: :text, text: text}] = synthetic.content
      assert text =~ "tool result missing"
    end

    test "drops orphan tool_result that has no preceding tool_call", %{session: session} do
      {:ok, _} =
        Agent.append_message(%{
          session_id: session.id,
          role: :user,
          content: "",
          tool_results: [%{"tool_use_id" => "call_nowhere", "content" => "x"}],
          turn: 1
        })

      {:ok, _} =
        Agent.append_message(%{session_id: session.id, role: :user, content: "hi", turn: 2})

      [%ReqLLM.Message{role: :user, content: [%{type: :text, text: "hi"}]}] = History.load(session.id)
    end

    test "trims to budget by dropping oldest", %{session: session} do
      for i <- 1..20 do
        {:ok, _} =
          Agent.append_message(%{
            session_id: session.id,
            role: :user,
            content: String.duplicate("x", 100),
            turn: i
          })
      end

      msgs = History.load(session.id, max_chars: 300)
      assert length(msgs) < 20
    end

    test "exclude_id removes the given message", %{session: session} do
      {:ok, m1} =
        Agent.append_message(%{session_id: session.id, role: :user, content: "first", turn: 1})

      {:ok, _m2} =
        Agent.append_message(%{session_id: session.id, role: :user, content: "second", turn: 2})

      msgs = History.load(session.id, exclude_id: m1.id)
      assert length(msgs) == 1
    end
  end
end
