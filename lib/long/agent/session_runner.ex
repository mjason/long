defmodule Long.Agent.SessionRunner do
  @moduledoc """
  Runs one turn of `Long.Agent.Loop` for a session in a supervised Task,
  broadcasting every Loop event over PubSub topic `"agent_session:<uuid>"`.

  LiveViews subscribe to that topic to render the conversation in real time.
  Message persistence happens via the Loop's `:on_message` callback so
  history survives reconnects.

  Backend resolution:

  1. If the session has an `llm_alias` and `Long.Agent.LLM.resolve/1` succeeds,
     use the resolved backend.
  2. Otherwise fall back to `Long.Agent.LLM.Backend.Echo` — lets the UI work
     out of the box without an API key.
  """

  alias Long.Agent
  alias Long.Agent.{LLM, Loop}

  @topic_prefix "agent_session:"
  @task_sup Long.Agent.TaskSup

  def topic(session_id), do: @topic_prefix <> session_id

  def subscribe(session_id), do: Phoenix.PubSub.subscribe(Long.PubSub, topic(session_id))

  def unsubscribe(session_id), do: Phoenix.PubSub.unsubscribe(Long.PubSub, topic(session_id))

  @doc """
  Persist the user message, then run the loop in a Task. Returns `:ok`;
  the task is fire-and-forget (callers observe progress via PubSub).
  """
  def send_user_message(session_id, text, opts \\ [])
      when is_binary(session_id) and is_binary(text) do
    with {:ok, session} <- Agent.get_session(session_id) do
      backend = resolve_backend(session)
      history = load_canonical_messages(session_id)
      next_turn = next_turn_no(history)

      {:ok, user_row} =
        Agent.append_message(%{
          session_id: session_id,
          role: :user,
          content: text,
          turn: next_turn
        })

      broadcast(session_id, {:message_persisted, %{message: user_row}})

      {:ok, _pid} =
        Task.Supervisor.start_child(@task_sup, fn ->
          run_loop(session_id, backend, history ++ [%{role: :user, content: text}], opts)
        end)

      :ok
    end
  end

  defp run_loop(session_id, backend, messages, opts) do
    broadcast(session_id, :loop_started)

    on_message = fn msg ->
      persisted = persist_message(session_id, msg)
      broadcast(session_id, {:message_persisted, %{message: persisted}})
    end

    try do
      Loop.run(
        Keyword.merge(
          [
            backend: backend,
            messages: messages,
            session_id: session_id,
            on_message: on_message,
            max_turns: Keyword.get(opts, :max_turns, 20)
          ],
          opts
        )
      )
      |> Enum.each(fn ev -> broadcast(session_id, ev) end)
    rescue
      e -> broadcast(session_id, {:loop_error, Exception.message(e)})
    end

    broadcast(session_id, :loop_ended)
  end

  defp persist_message(session_id, msg) do
    {content, tool_calls, tool_results, blocks} = decompose(msg.content)

    {:ok, row} =
      Agent.append_message(%{
        session_id: session_id,
        role: msg.role,
        content: content,
        blocks: %{"items" => blocks},
        tool_calls: tool_calls,
        tool_results: tool_results,
        turn: Map.get(msg, :turn, 0)
      })

    row
  end

  defp decompose(content) when is_binary(content), do: {content, [], [], []}

  defp decompose(content) when is_list(content) do
    {text_parts, tool_calls, tool_results} =
      Enum.reduce(content, {[], [], []}, fn
        %{type: :text, text: t}, {txt, tc, tr} -> {[t | txt], tc, tr}
        %{type: :thinking, thinking: _t}, acc -> acc
        %{type: :tool_use} = b, {txt, tc, tr} -> {txt, [tool_use_to_map(b) | tc], tr}
        %{type: :tool_result} = b, {txt, tc, tr} -> {txt, tc, [tool_result_to_map(b) | tr]}
        _, acc -> acc
      end)

    flat_text = text_parts |> Enum.reverse() |> Enum.join("\n")

    {flat_text, Enum.reverse(tool_calls), Enum.reverse(tool_results),
     content |> Enum.map(&block_for_storage/1)}
  end

  defp decompose(_), do: {"", [], [], []}

  defp block_for_storage(b), do: stringify_keys(b)

  defp stringify_keys(map) when is_map(map) do
    Enum.into(map, %{}, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp tool_use_to_map(%{id: id, name: name, input: input}) do
    %{"id" => id, "name" => name, "input" => input}
  end

  defp tool_result_to_map(%{tool_use_id: id, content: c}) do
    %{"tool_use_id" => id, "content" => to_string_safe(c)}
  end

  defp to_string_safe(c) when is_binary(c), do: c
  defp to_string_safe(c), do: inspect(c)

  defp resolve_backend(%{llm_alias: nil}), do: %LLM.Backend.Echo{}

  defp resolve_backend(%{llm_alias: alias_name}) when is_binary(alias_name) do
    case LLM.resolve(alias_name) do
      {:ok, backend} -> backend
      _ -> %LLM.Backend.Echo{}
    end
  end

  defp resolve_backend(_), do: %LLM.Backend.Echo{}

  defp load_canonical_messages(session_id) do
    {:ok, all} = Agent.list_messages()

    all
    |> Enum.filter(&(&1.session_id == session_id))
    |> Enum.sort_by(& &1.inserted_at, DateTime)
    |> Enum.map(&row_to_canonical/1)
  end

  defp row_to_canonical(row) do
    text_block = if (row.content || "") != "", do: [%{type: :text, text: row.content}], else: []

    tool_use_blocks =
      Enum.map(row.tool_calls || [], fn t ->
        %{type: :tool_use, id: t["id"], name: t["name"], input: t["input"] || %{}}
      end)

    tool_result_blocks =
      Enum.map(row.tool_results || [], fn t ->
        %{type: :tool_result, tool_use_id: t["tool_use_id"], content: t["content"]}
      end)

    %{
      role: row.role,
      content: tool_result_blocks ++ text_block ++ tool_use_blocks,
      turn: row.turn
    }
  end

  defp next_turn_no([]), do: 1
  defp next_turn_no(msgs), do: (msgs |> Enum.map(& &1.turn) |> Enum.max()) + 1

  defp broadcast(session_id, msg) do
    Phoenix.PubSub.broadcast(Long.PubSub, topic(session_id), msg)
  end
end
