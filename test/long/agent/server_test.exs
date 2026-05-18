defmodule Long.Agent.ServerTest do
  use Long.DataCase, async: false

  alias Long.Agent
  alias Long.Agent.Server
  alias Long.Test.LLMConsumerMock

  setup do
    LLMConsumerMock.setup_table()
    LLMConsumerMock.reset()

    Application.put_env(:long, :llm_consumer, LLMConsumerMock)

    # Ensure we have a default LLM so Server.start_turn doesn't bail to
    # the echo path. Provider/model are dummies — Mock intercepts anyway.
    {:ok, _llm} =
      Agent.register_llm(%{
        alias: "test_llm",
        kind: :openai,
        provider: "openai",
        model: "test-model",
        enabled: true,
        default: true
      })

    {:ok, session} = Agent.start_session(%{title: "server-test", llm_alias: "test_llm"})

    on_exit(fn ->
      Server.terminate_session(session.id)
      LLMConsumerMock.reset()
      Application.delete_env(:long, :llm_consumer)
    end)

    {:ok, session: session}
  end

  defp send_and_wait(session_id, text, timeout \\ 2_000) do
    Long.Jido.SessionRunner.subscribe(session_id)
    :ok = Server.send_user_message(session_id, text, llm_consumer: LLMConsumerMock)
    wait_for(:loop_ended, timeout)
    Long.Jido.SessionRunner.unsubscribe(session_id)
  end

  defp wait_for(target, timeout) do
    receive do
      ^target -> :ok
      _other -> wait_for(target, timeout)
    after
      timeout -> :timeout
    end
  end

  describe "lifecycle" do
    test "spawns a Server under DynamicSupervisor on first send", %{session: session} do
      :ok = Server.send_user_message(session.id, "hi")
      pid = Server.lookup(session.id)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "terminate_session stops the Server and clears its snapshot", %{session: session} do
      :ok = Server.send_user_message(session.id, "hi")
      pid = Server.lookup(session.id)
      assert is_pid(pid)

      :ok = Server.terminate_session(session.id)
      refute Process.alive?(pid)
      assert {:error, _} = Agent.get_turn_snapshot(session.id)
    end
  end

  describe "state machine — final-answer path" do
    test "broadcasts loop_started → turn_start → done → loop_ended", %{session: session} do
      Long.Jido.SessionRunner.subscribe(session.id)

      LLMConsumerMock.push_response(session.id, %{type: :final_answer, text: "hello back"})

      :ok = Server.send_user_message(session.id, "ping", llm_consumer: LLMConsumerMock)

      assert_receive :loop_started, 2_000
      assert_receive {:turn_start, 1}, 2_000
      assert_receive {:done, %{reason: :no_tool_call}}, 2_000
      assert_receive :loop_ended, 2_000

      snap = Server.snapshot(session.id)
      assert snap.stage == :idle
      assert snap.turn == 1
    end

    test "persists the assistant message and snapshot", %{session: session} do
      LLMConsumerMock.push_response(session.id, %{type: :final_answer, text: "the answer"})

      send_and_wait(session.id, "what?")

      {:ok, msgs} = Agent.list_messages()
      session_msgs = Enum.filter(msgs, &(&1.session_id == session.id))

      assert Enum.any?(session_msgs, &(&1.role == :user and &1.content == "what?"))
      assert Enum.any?(session_msgs, &(&1.role == :assistant and &1.content == "the answer"))

      {:ok, snap} = Agent.get_turn_snapshot(session.id)
      assert snap.stage == :idle
      assert snap.turn == 1
      assert snap.last_assistant_text == "the answer"
    end
  end

  describe "max_turns scope" do
    test "max_turns counts iterations within a user message, not session lifetime",
         %{session: session} do
      # Two user messages — each does one tool round (two LLM iterations).
      # With max_turns: 2 explicitly set on BOTH (so the test doesn't
      # depend on opts leaking between messages), the second message
      # must still complete: each message gets a fresh iteration budget.
      # If `state.iteration` weren't reset in start_llm_turn, message 2
      # would resume at iter=2 and trip :max_turns on its first tool
      # round.
      Application.put_env(:long, :default_tools, [Long.Test.EchoTool])

      on_exit(fn ->
        Server.terminate_session(session.id)
        Application.delete_env(:long, :default_tools)
      end)

      Long.Jido.SessionRunner.subscribe(session.id)

      send_tool_then_final = fn id, label ->
        LLMConsumerMock.push_response(session.id, %{
          type: :tool_calls,
          tool_calls: [%{id: id, name: "echo_tool", arguments: %{text: label}}]
        })

        LLMConsumerMock.push_response(session.id, %{
          type: :final_answer,
          text: "#{label} done"
        })
      end

      send_tool_then_final.("c1", "round one")

      :ok =
        Server.send_user_message(session.id, "first",
          llm_consumer: LLMConsumerMock,
          max_turns: 2
        )

      assert_receive {:done, %{reason: :no_tool_call}}, 2_000
      assert_receive :loop_ended, 2_000

      send_tool_then_final.("c2", "round two")

      :ok =
        Server.send_user_message(session.id, "second",
          llm_consumer: LLMConsumerMock,
          max_turns: 2
        )

      assert_receive {:done, %{reason: reason}}, 2_000

      assert reason == :no_tool_call,
             "expected :no_tool_call, got #{inspect(reason)} (iteration reset regressed)"

      assert_receive :loop_ended, 2_000

      snap = Server.snapshot(session.id)
      assert snap.stage == :idle
    end

    test "max_turns opt does not leak across user messages", %{session: session} do
      # Message 1 overrides max_turns: 7 explicitly; message 2 passes
      # no opt and must run under the default cap, not inherit 7.
      # We check the snapshot directly because the symptom of a leak
      # would be silent (next message's cap quietly stays at the old
      # value), not a visible error.
      Long.Jido.SessionRunner.subscribe(session.id)

      LLMConsumerMock.push_response(session.id, %{type: :final_answer, text: "msg1"})

      :ok =
        Server.send_user_message(session.id, "tight",
          llm_consumer: LLMConsumerMock,
          max_turns: 7
        )

      assert_receive :loop_ended, 2_000
      assert Server.snapshot(session.id).max_turns == 7

      LLMConsumerMock.push_response(session.id, %{type: :final_answer, text: "msg2"})

      :ok = Server.send_user_message(session.id, "loose", llm_consumer: LLMConsumerMock)
      assert_receive :loop_ended, 2_000

      # Must have reset to the configured default, not stuck at 7.
      default = Application.get_env(:long, :default_max_turns, 40)
      assert Server.snapshot(session.id).max_turns == default
    end

    test "hitting iteration cap folds history via Summarizer and continues", %{
      session: session
    } do
      # When iteration hits max_turns we should NOT terminate; instead
      # the older portion of state.messages gets folded into a summary,
      # iteration resets, and the loop keeps going. With max_turns: 1
      # the budget is exhausted right after the first tool round, which
      # is exactly what triggers compression. After compression resets
      # iteration, the loop runs a second LLM call that returns
      # final_answer — overall: tool round → compression → final answer
      # with no :max_turns trip.
      test_pid = self()

      Application.put_env(:long, :default_tools, [Long.Test.EchoTool])
      Application.put_env(:long, :summarizer, fn _prior, rows, _alias ->
        # Forward the rows we were asked to fold so the test can assert
        # the conversion to row-shape happened correctly.
        send(test_pid, {:summarizer_called, rows})
        {:ok, "folded summary of earlier turns"}
      end)

      on_exit(fn ->
        Server.terminate_session(session.id)
        Application.delete_env(:long, :default_tools)
        Application.delete_env(:long, :summarizer)
      end)

      Long.Jido.SessionRunner.subscribe(session.id)

      # Round 1: tool_calls trips the iter=1, max=1 budget on completion.
      LLMConsumerMock.push_response(session.id, %{
        type: :tool_calls,
        tool_calls: [%{id: "c1", name: "echo_tool", arguments: %{text: "go"}}]
      })

      # After compression resets iteration we expect a second LLM call —
      # give it a final answer this time.
      LLMConsumerMock.push_response(session.id, %{type: :final_answer, text: "wrapped"})

      :ok =
        Server.send_user_message(session.id, "compress me",
          llm_consumer: LLMConsumerMock,
          max_turns: 1
        )

      # Summarizer must have been invoked with a non-empty row list
      # whose first row is the user message ("compress me").
      assert_receive {:summarizer_called, rows}, 2_000
      assert [%{role: :user, content: "compress me"} | _] = rows

      assert_receive {:done, %{reason: :no_tool_call}}, 2_000
      refute_receive {:done, %{reason: :max_turns}}, 100
    end

    test "falls back to :max_turns after the compression cap", %{session: session} do
      Application.put_env(:long, :default_tools, [Long.Test.EchoTool])
      Application.put_env(:long, :summarizer, fn _prior, _rows, _alias ->
        {:ok, "summary"}
      end)

      on_exit(fn ->
        Server.terminate_session(session.id)
        Application.delete_env(:long, :default_tools)
        Application.delete_env(:long, :summarizer)
      end)

      Long.Jido.SessionRunner.subscribe(session.id)

      # With max_turns: 1, each iteration immediately exhausts the budget
      # and triggers a compression. After 3 compressions the Server must
      # give up with :max_turns. Push enough tool_calls to feed every
      # cycle: 1 (initial) + 3 (post-compression) = 4 calls before the
      # 4th budget exhaustion gives up.
      for i <- 1..4 do
        LLMConsumerMock.push_response(session.id, %{
          type: :tool_calls,
          tool_calls: [%{id: "loop#{i}", name: "echo_tool", arguments: %{text: "#{i}"}}]
        })
      end

      :ok =
        Server.send_user_message(session.id, "loop forever",
          llm_consumer: LLMConsumerMock,
          max_turns: 1
        )

      assert_receive {:done, %{reason: :max_turns}}, 2_000
    end
  end

  describe "inbox queue" do
    test "messages sent while busy are processed after the current turn", %{session: session} do
      # Queue up two LLM responses; we'll send two messages back-to-back.
      LLMConsumerMock.push_response(session.id, %{type: :final_answer, text: "first"})
      LLMConsumerMock.push_response(session.id, %{type: :final_answer, text: "second"})

      Long.Jido.SessionRunner.subscribe(session.id)

      :ok = Server.send_user_message(session.id, "msg-1", llm_consumer: LLMConsumerMock)
      :ok = Server.send_user_message(session.id, "msg-2", llm_consumer: LLMConsumerMock)

      assert_receive :loop_started, 2_000
      assert_receive {:turn_start, 1}, 2_000
      assert_receive :loop_ended, 2_000

      assert_receive :loop_started, 2_000
      assert_receive {:turn_start, 2}, 2_000
      assert_receive :loop_ended, 2_000

      snap = Server.snapshot(session.id)
      assert snap.stage == :idle
      assert snap.turn == 2
    end
  end

  describe "abort" do
    test "drops back to :idle and broadcasts loop_error", %{session: session} do
      # No mock response queued — Mock falls back to a quick :final_answer "ok",
      # so we abort before that lands by casting :abort right after send.
      Long.Jido.SessionRunner.subscribe(session.id)
      :ok = Server.send_user_message(session.id, "abort-me", llm_consumer: LLMConsumerMock)
      :ok = Server.abort(session.id)

      # Either the final_answer wins the race (fine — loop_ended) or
      # the abort wins (loop_error + loop_ended). Both end at loop_ended.
      assert_receive :loop_ended, 2_000

      snap = Server.snapshot(session.id)
      assert snap.stage == :idle
    end
  end

  describe "tool timeout" do
    test "hung tool is killed and synthesises a timeout tool_result", %{session: session} do
      Application.put_env(:long, :default_tools, [Long.Test.HangTool])
      Application.put_env(:long, :tool_timeout_ms, 50)

      on_exit(fn ->
        # Terminate the Server BEFORE clearing the Application env, so
        # any in-flight `start_turn` won't see a half-cleared default.
        Server.terminate_session(session.id)
        Application.delete_env(:long, :default_tools)
        Application.delete_env(:long, :tool_timeout_ms)
      end)

      # 1st LLM response → tool_calls(hang_tool); 2nd → final_answer
      LLMConsumerMock.push_response(session.id, %{
        type: :tool_calls,
        tool_calls: [%{id: "call_1", name: "hang_tool", arguments: %{}}]
      })

      LLMConsumerMock.push_response(session.id, %{type: :final_answer, text: "after timeout"})

      Long.Jido.SessionRunner.subscribe(session.id)
      :ok = Server.send_user_message(session.id, "hang please", llm_consumer: LLMConsumerMock)

      # The tool_done event carries the synthesised timeout error.
      assert_receive {:tool_done, %{id: "call_1", data: data}}, 2_000
      assert is_map(data) and Map.get(data, "error") =~ "timed out"

      # The Server continues into the next LLM turn and finishes cleanly.
      assert_receive :loop_ended, 2_000

      snap = Server.snapshot(session.id)
      assert snap.stage == :idle
    end
  end

  describe "crash recovery" do
    test "Server reinitializes from snapshot on restart", %{session: session} do
      LLMConsumerMock.push_response(session.id, %{type: :final_answer, text: "first turn"})
      send_and_wait(session.id, "round one")

      pid = Server.lookup(session.id)
      assert is_pid(pid)

      # Snapshot should have turn=1, stage=:idle.
      {:ok, snap_before} = Agent.get_turn_snapshot(session.id)
      assert snap_before.turn == 1
      assert snap_before.stage == :idle

      # Brutal-kill the Server; DynamicSupervisor restarts it with
      # :transient restart (because the exit reason was :kill, abnormal).
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

      # Give the supervisor a moment to restart.
      Process.sleep(100)
      new_pid = Server.lookup(session.id)
      assert is_pid(new_pid)
      assert new_pid != pid

      restored = Server.snapshot(session.id)
      assert restored.turn == 1
      assert restored.stage == :idle
      assert restored.llm_alias == "test_llm"
    end
  end
end
