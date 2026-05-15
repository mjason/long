defmodule Long.Jido.SessionRunner do
  @moduledoc """
  Phase B v2 — drop-in replacement for `Long.Agent.SessionRunner`. Same
  public API (`topic/1`, `subscribe/1`, `unsubscribe/1`,
  `send_user_message/3`) and same PubSub topic format
  (`"agent_session:<uuid>"`), but the agent loop is `Long.Jido.Loop`
  instead of `Long.Agent.Loop`.

  Behaviour intentionally matches the legacy runner so LiveView / Bot /
  CLI don't have to change. The Loop's event/message callbacks are
  translated into the same PubSub event protocol; messages are persisted
  to the Phase 0 `Long.Agent.Message` schema.

  Differences vs legacy SessionRunner (v2 v1 trade-offs):

  - No `:llm_chunk` / `:tool_output` streaming (jido's `ReqLLM.StreamResponse`
    is fully drained via `classify/1` before we know what to emit). UI
    falls back to "thinking" indicator. Phase B v3 can re-introduce
    real streaming.
  - Echo fallback removed — if `session.llm_alias` is nil, we delegate
    to the legacy runner so dev/test paths keep working.
  """

  require Logger

  alias Long.Agent
  alias Long.Agent.Memory.Recall
  alias Long.Jido.{History, Loop}

  @topic_prefix "agent_session:"
  @task_sup Long.Agent.TaskSup

  @default_tools [
    Long.Jido.Tools.CodeRun,
    Long.Jido.Tools.FileRead,
    Long.Jido.Tools.FileWrite,
    Long.Jido.Tools.FilePatch,
    Long.Jido.Tools.HttpFetch,
    Long.Jido.Tools.UpdateWorkingCheckpoint,
    Long.Jido.Tools.MemoryRemember,
    Long.Jido.Tools.MemoryRecall,
    Long.Jido.Tools.MemorySearch,
    Long.Jido.Tools.StartLongTermUpdate,
    Long.Jido.Tools.WebSearch,
    Long.Jido.Tools.WebScan,
    Long.Jido.Tools.WebExecuteJs,
    Long.Jido.Tools.ScheduleTask,
    Long.Jido.Tools.ListScheduledTasks,
    Long.Jido.Tools.CancelScheduledTask,
    Long.Jido.Tools.SendMedia,
    Long.Jido.Tools.AskUser,
    Long.Jido.Tools.AgentStatus
  ]

  def topic(session_id), do: @topic_prefix <> session_id
  def subscribe(session_id), do: Phoenix.PubSub.subscribe(Long.PubSub, topic(session_id))
  def unsubscribe(session_id), do: Phoenix.PubSub.unsubscribe(Long.PubSub, topic(session_id))

  def send_user_message(session_id, text, opts \\ [])
      when is_binary(session_id) and is_binary(text) do
    with {:ok, session} <- Agent.get_session(session_id) do
      Task.Supervisor.start_child(@task_sup, fn ->
        execute(session_id, session, text, opts)
      end)
    end
  end

  # ── Inner execution ──────────────────────────────────────────────────────

  defp execute(session_id, %{llm_alias: nil}, text, opts) do
    # No alias configured → fall back to the legacy runner (Echo backend).
    Long.Agent.SessionRunner.send_user_message(session_id, text, opts)
  end

  defp execute(session_id, %{llm_alias: alias_name}, text, opts) do
    broadcast(session_id, :loop_started)

    # An atomic counter scoped to this task replaces the previous
    # Process-dict counter. `next_turn_no/1` seeds it from the DB so
    # turn numbers stay monotonic across separate user messages.
    turn_counter = :counters.new(1, [:atomics])
    :counters.put(turn_counter, 1, next_turn_no(session_id))

    workspace_root =
      Application.get_env(:long, Long.Agent, [])[:workspace_root] ||
        Path.expand("priv/agent/workspace", File.cwd!())

    # Load prior turns + (when context blows the budget) ask the LLM
    # to compress the oldest portion into `session.summary`. History
    # is loaded BEFORE we persist the current user message via
    # `on_message` (Loop fires that callback as its first act), so no
    # exclude_id is needed yet.
    %{system_addendum: summary_addendum, messages: history} =
      History.load_or_compress(session_id, alias_name)

    # Pull keyword-relevant session + global memories so the agent
    # has stable facts at hand without having to explicitly call
    # `memory_recall` every turn. `bump: false` — we'd lose signal if
    # auto-recall counted; only the explicit tool call bumps usage.
    memory_addendum =
      text
      |> Recall.recall(session_id: session_id, limit: 8, bump: false)
      |> Recall.format_for_prompt()

    addendum = merge_addenda(summary_addendum, memory_addendum)

    result =
      try do
        Loop.run(text,
          tools: @default_tools,
          llm_alias: alias_name,
          attachments: Keyword.get(opts, :attachments, []),
          history: history,
          system_addendum: addendum,
          tool_context: %{session_id: session_id, workspace_root: workspace_root},
          on_event: event_handler(session_id),
          on_message: message_handler(session_id, turn_counter)
        )
      rescue
        e ->
          stacktrace = __STACKTRACE__

          Logger.error(
            "Long.Jido.SessionRunner loop crashed: " <>
              Exception.format(:error, e, stacktrace)
          )

          _ = ErrorTracker.report(e, stacktrace, %{session_id: session_id, source: "jido.loop"})
          broadcast(session_id, {:loop_error, Exception.message(e)})
          %{result: :error, error: e}
      end

    broadcast(session_id, {:done, done_reason(result)})
    broadcast(session_id, :loop_ended)
  end

  defp done_reason(%{result: :done, text: _}), do: %{reason: :no_tool_call}
  defp done_reason(%{result: :asked_user, ask_user: a}), do: %{reason: :asked_user, data: a}
  defp done_reason(%{result: :max_turns}), do: %{reason: :max_turns}
  defp done_reason(%{result: :error, error: e}), do: %{reason: :error, error: e}
  defp done_reason(_), do: %{reason: :unknown}

  # Combine the conversation-summary section (from History) and the
  # memory section (from Recall) into a single system-prompt
  # addendum. Either may be nil/empty.
  defp merge_addenda(nil, ""), do: nil
  defp merge_addenda(summary, ""), do: summary
  defp merge_addenda(nil, memory), do: memory
  defp merge_addenda(summary, memory), do: summary <> "\n\n" <> memory

  # ── Event → PubSub translation ───────────────────────────────────────────

  defp event_handler(session_id) do
    fn
      {:turn_start, n} ->
        broadcast(session_id, {:turn_start, n})

      {:tool_calls, _calls, _usage} ->
        :ok

      {:tool_start, name, args, id} ->
        broadcast(
          session_id,
          {:tool_start, %{id: id, name: name, args: args, index: 0, count: 1}}
        )

      {:tool_done, name, id, result} ->
        data =
          case result do
            {:ok, x} -> x
            {:error, e} -> %{"status" => "error", "msg" => inspect(e)}
            other -> other
          end

        broadcast(session_id, {:tool_done, %{id: id, name: name, data: data, exit?: false}})

      {:ask_user, payload} ->
        # `payload` shape: %{question, candidates}. LiveView expects string keys.
        broadcast(
          session_id,
          {:ask_user,
           %{"question" => payload[:question], "candidates" => payload[:candidates] || []}}
        )

      _ ->
        :ok
    end
  end

  # ── Message → DB + PubSub ────────────────────────────────────────────────

  defp message_handler(session_id, turn_counter) do
    fn tagged ->
      attrs = build_message_attrs(session_id, tagged, turn_counter)

      if attrs do
        case Agent.append_message(attrs) do
          {:ok, row} ->
            broadcast(session_id, {:message_persisted, %{message: row}})

          other ->
            # Silently dropping a tool_result here used to corrupt the
            # next turn's history (the LLM API rejects an
            # assistant.tool_calls without a matching tool_result).
            Logger.error(
              "Long.Jido.SessionRunner failed to persist message " <>
                "(session_id=#{session_id}, role=#{inspect(attrs[:role])}, " <>
                "turn=#{inspect(attrs[:turn])}): #{inspect(other)}"
            )
        end
      end
    end
  end

  defp build_message_attrs(session_id, {:user, _msg, text}, counter) do
    %{session_id: session_id, role: :user, content: text, turn: bump(counter)}
  end

  defp build_message_attrs(session_id, {:assistant, _msg, %{text: text, tool_calls: tcs}}, counter) do
    tool_calls =
      Enum.map(tcs || [], fn tc ->
        %{"id" => tc.id, "name" => tc.name, "input" => tc.arguments}
      end)

    %{
      session_id: session_id,
      role: :assistant,
      content: text || "",
      tool_calls: tool_calls,
      turn: bump(counter)
    }
  end

  defp build_message_attrs(session_id, {:tool, %ReqLLM.Message{} = msg, _}, counter) do
    %{
      session_id: session_id,
      role: :user,
      content: "",
      tool_results: [%{"tool_use_id" => msg.tool_call_id, "content" => extract_text(msg.content)}],
      turn: bump(counter)
    }
  end

  defp build_message_attrs(_, _, _), do: nil

  defp extract_text(parts) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{type: :text, text: t} -> t
      %{"type" => "text", "text" => t} -> t
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  defp extract_text(text) when is_binary(text), do: text
  defp extract_text(_), do: ""

  defp bump(counter) do
    current = :counters.get(counter, 1)
    :counters.add(counter, 1, 1)
    current
  end

  defp next_turn_no(session_id) do
    case Agent.list_messages() do
      {:ok, all} ->
        case all |> Enum.filter(&(&1.session_id == session_id)) |> Enum.map(& &1.turn) do
          [] -> 1
          turns -> Enum.max(turns) + 1
        end

      _ ->
        1
    end
  end

  defp broadcast(session_id, msg) do
    Phoenix.PubSub.broadcast(Long.PubSub, topic(session_id), msg)
  end
end
