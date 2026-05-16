defmodule Long.Test.LLMConsumerMock do
  @moduledoc """
  Pre-canned `Long.Agent.LLMConsumer` implementation for testing
  `Long.Agent.Server`'s state machine without a real LLM.

  Tests `push_response/2` one or more responses keyed by session_id;
  each call to `start/5` pops the head of the queue and `send`s it
  back to the owner Server. Falls back to a `:final_answer "ok"` if
  no script entry remains.
  """

  @behaviour Long.Agent.LLMConsumer

  @ets :long_test_llm_responses

  def setup_table do
    case :ets.whereis(@ets) do
      :undefined -> :ets.new(@ets, [:public, :named_table, :set])
      _ -> :ok
    end
  end

  @doc """
  Queue one classification response for `session_id`. Each subsequent
  `start/5` call from that session consumes one queue entry.
  """
  def push_response(session_id, %{type: type} = response) when type in [:final_answer, :tool_calls] do
    setup_table()
    existing = case :ets.lookup(@ets, session_id) do
      [{^session_id, list}] -> list
      _ -> []
    end
    :ets.insert(@ets, {session_id, existing ++ [response]})
  end

  @doc "Reset the script for a session (or all sessions)."
  def reset(session_id) when is_binary(session_id) do
    setup_table()
    :ets.delete(@ets, session_id)
  end

  def reset, do: (:ets.whereis(@ets) != :undefined and :ets.delete_all_objects(@ets))

  @impl true
  def start(owner, ref, _messages, _tools, opts) do
    session_id = Keyword.get(opts, :session_id) || infer_session(owner)

    response = next_response(session_id)

    pid =
      spawn(fn ->
        send(owner, {:llm_result, ref, {:ok, full_classification(response)}})
      end)

    {:ok, pid}
  end

  defp next_response(nil), do: default_response()

  defp next_response(session_id) do
    # The Server can outlive the test that created the ETS table (a
    # restarted child fires its first :llm_result after on_exit ran).
    # Treat a missing table as "no script, default response" instead
    # of crashing.
    if :ets.whereis(@ets) == :undefined do
      default_response()
    else
      case :ets.lookup(@ets, session_id) do
        [{^session_id, [head | rest]}] ->
          :ets.insert(@ets, {session_id, rest})
          head

        _ ->
          default_response()
      end
    end
  end

  defp default_response, do: %{type: :final_answer, text: "ok"}

  defp infer_session(owner) when is_pid(owner) do
    # Server is registered under {Registry, session_id}; reverse-look-up
    # the keys this owner holds and grab the first (only) one.
    case Registry.keys(Long.Agent.Server.Registry, owner) do
      [sid | _] -> sid
      _ -> nil
    end
  end

  defp full_classification(%{type: :final_answer, text: text}) do
    %{type: :final_answer, text: text, thinking: nil, tool_calls: [], finish_reason: :stop, usage: %{}}
  end

  defp full_classification(%{type: :tool_calls, tool_calls: tcs} = resp) do
    %{
      type: :tool_calls,
      text: resp[:text] || "",
      thinking: nil,
      tool_calls: tcs,
      finish_reason: :tool_calls,
      usage: %{}
    }
  end
end
