defmodule Long.Agent.Server do
  @moduledoc """
  One GenServer per chat session, holding the ReAct loop state machine
  and the lifecycle of every subordinate process (LLM consumer, tool
  tasks).

  - **Process-per-session** registered in `Long.Agent.Server.Registry`,
    supervised by `Long.Agent.Server.Supervisor` (a DynamicSupervisor).
  - **State machine**: `:idle → :calling_llm → :running_tools
    → :idle | :asked_user`. Stage transitions write a row to
    `Long.Agent.TurnSnapshot` so a crash-restart resumes the
    half-finished turn instead of dropping it.
  - Subordinate processes are **monitored, not linked** — crashes
    surface as `DOWN` messages the state machine handles explicitly.
  - User input is cast; messages received mid-turn land in an internal
    inbox queue that drains on returning to `:idle`.

  PubSub event protocol: `:loop_started`, `{:turn_start, n}`,
  `{:tool_start, …}`, `{:tool_done, …}`, `{:message_persisted, …}`,
  `{:done, reason}`, `:loop_ended`, `{:ask_user, …}`, `{:loop_error, msg}`.
  """

  use GenServer, restart: :transient, shutdown: 10_000

  require Logger

  alias Long.Agent
  alias Long.Agent.Memory.Recall
  alias Long.Agent.Skill.Store, as: SkillStore
  alias Long.Jido.{History, Loop}

  @topic_prefix "agent_session:"
  @task_sup Long.Agent.TaskSup
  @default_max_turns 40
  @max_tool_calls_per_turn 4
  # When `iteration` hits `max_turns` we don't just stop — we fold the
  # in-flight messages into a summary via `Long.Jido.Summarizer` and
  # reset the counter so legitimate long tasks (deep research, big
  # refactors, …) can finish. `compression_count` caps how many times
  # this rollover can happen per user message; beyond it we fall back
  # to the original `:max_turns` `end_turn`. Guards against models
  # genuinely stuck in a loop.
  @max_in_flight_compressions 3
  @default_tool_timeout_ms 60_000

  # ── Client API ────────────────────────────────────────────────────────

  @doc "Start the GenServer under the DynamicSupervisor. Use `Long.Agent.Server.Supervisor.start_session/1`."
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  @doc """
  Cast a new user message. If the Server is busy the message is queued
  and runs after the current turn. `opts` may carry `:attachments`,
  `:llm_alias`, `:max_turns` (per-message override of the iteration
  cap), and `:llm_consumer` (test seam).
  """
  def send_user_message(session_id, text, opts \\ [])
      when is_binary(session_id) and is_binary(text) do
    case ensure_started(session_id) do
      {:ok, _pid} -> GenServer.cast(via(session_id), {:user_message, text, opts})
      err -> err
    end
  end

  @doc "Append a `/btw` follow-up note that gets injected into the next LLM call as an extra user-role message."
  def add_btw(session_id, note) when is_binary(session_id) and is_binary(note) do
    case lookup(session_id) do
      nil -> :no_server
      pid -> GenServer.cast(pid, {:btw, note})
    end
  end

  @doc "Kill any in-flight LLM consumer / tool tasks and drop back to `:idle`. The user gets `{:loop_error, \"aborted\"}` via PubSub."
  def abort(session_id) when is_binary(session_id) do
    case lookup(session_id) do
      nil -> :no_server
      pid -> GenServer.cast(pid, :abort)
    end
  end

  @doc """
  Return a snapshot of the current state for `/status`-style UI.
  Synchronous call so the caller can render immediately.
  """
  def snapshot(session_id) when is_binary(session_id) do
    case lookup(session_id) do
      nil ->
        %{stage: :idle, turn: 0, current_request: nil}

      pid ->
        try do
          GenServer.call(pid, :snapshot, 5_000)
        catch
          :exit, _ -> %{stage: :idle, turn: 0, current_request: nil}
        end
    end
  end

  @doc "Terminate the Server and drop its persisted snapshot. Used by `/clear`."
  def terminate_session(session_id) when is_binary(session_id) do
    case lookup(session_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Long.Agent.Server.Supervisor, pid)
    end

    _ =
      case Agent.get_turn_snapshot(session_id) do
        {:ok, snap} -> Agent.destroy_turn_snapshot(snap)
        _ -> :ok
      end

    :ok
  end

  @doc "Look up the live Server pid for a session, or `nil`."
  def lookup(session_id) when is_binary(session_id) do
    case Registry.lookup(Long.Agent.Server.Registry, session_id) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  defp via(session_id),
    do: {:via, Registry, {Long.Agent.Server.Registry, session_id}}

  # Spawn or look up. Used by `send_user_message/3` so the chat
  # frontend doesn't have to remember whether a Server already exists.
  defp ensure_started(session_id) do
    case lookup(session_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case Agent.get_session(session_id) do
          {:ok, session} ->
            DynamicSupervisor.start_child(
              Long.Agent.Server.Supervisor,
              {__MODULE__, session_id: session_id, session: session}
            )

          err ->
            err
        end
    end
  end

  # ── GenServer callbacks ──────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    session_id = Keyword.fetch!(opts, :session_id)
    session = Keyword.get(opts, :session)

    state = %{
      session_id: session_id,
      session: session,
      llm_alias: session && session.llm_alias,

      # State-machine fields
      stage: :idle,
      # `turn` is a session-monotonic counter persisted on every
      # message row, used for `sort turn: :asc` history ordering and
      # snapshot semantics.
      turn: 0,
      # `iteration` counts LLM round-trips *within the current user
      # message* and resets in `start_llm_turn/4`. This is what the
      # `max_turns` cap actually compares against — without the reset
      # an old session would carry its lifetime turn count forward
      # and every new message would trip max_turns on the first tool
      # round.
      iteration: 0,
      # Number of in-flight compressions already triggered for the
      # current user message. Resets per message alongside `iteration`.
      compression_count: 0,
      messages: [],
      tools: default_tools(),
      tool_ctx: %{},

      # In-flight LLM
      llm_ref: nil,
      llm_pid: nil,
      llm_monitor: nil,

      # In-flight tools (tool_monitors: %{ref => {%Task{}, tc, timer_ref}})
      pending_tool_calls: %{},
      tool_results: %{},
      tool_monitors: %{},

      # Queued user messages (when stage != :idle)
      inbox: :queue.new(),

      # /btw notes pulled into next LLM call
      btws: [],

      # /status preview of what's being worked on
      current_request: nil,

      max_turns: Keyword.get(opts, :max_turns, default_max_turns()),
      llm_consumer: Keyword.get(opts, :llm_consumer, default_llm_consumer())
    }

    {:ok, state, {:continue, :restore_or_idle}}
  end

  defp default_llm_consumer,
    do: Application.get_env(:long, :llm_consumer, Long.Agent.LLMConsumer)

  defp default_max_turns,
    do: Application.get_env(:long, :default_max_turns, @default_max_turns)

  @impl true
  def handle_continue(:restore_or_idle, state) do
    case Agent.get_turn_snapshot(state.session_id) do
      {:ok, snap} -> {:noreply, restore_from_snapshot(state, snap)}
      _ -> {:noreply, state}
    end
  end

  # ── Public casts ─────────────────────────────────────────────────────

  @impl true
  def handle_cast({:user_message, text, opts}, %{stage: :idle} = state) do
    {:noreply, start_turn(state, text, opts)}
  end

  def handle_cast({:user_message, text, opts}, %{stage: :asked_user} = state) do
    # Treat the answer to an ask_user prompt the same as a fresh user
    # turn — the LLM sees it as the next user message.
    {:noreply, start_turn(%{state | stage: :idle}, text, opts)}
  end

  def handle_cast({:user_message, text, opts}, state) do
    {:noreply, %{state | inbox: :queue.in({text, opts}, state.inbox)}}
  end

  def handle_cast({:btw, note}, state) do
    state = %{state | btws: state.btws ++ [note]}
    persist_snapshot(state)
    {:noreply, state}
  end

  def handle_cast(:abort, state) do
    kill_subordinates(state)
    broadcast(state.session_id, {:loop_error, "aborted"})
    broadcast(state.session_id, :loop_ended)

    state =
      %{
        state
        | stage: :idle,
          llm_ref: nil,
          llm_pid: nil,
          llm_monitor: nil,
          pending_tool_calls: %{},
          tool_results: %{},
          tool_monitors: %{},
          current_request: nil
      }

    persist_snapshot(state)
    {:noreply, drain_inbox(state)}
  end

  # ── Sync calls ───────────────────────────────────────────────────────

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, public_snapshot(state), state}
  end

  # ── Worker messages ──────────────────────────────────────────────────

  @impl true
  def handle_info({:llm_result, ref, result}, %{llm_ref: ref} = state) do
    state = demonitor_llm(state)
    {:noreply, handle_llm_result(state, result)}
  end

  # Stale (came after abort / next turn started). Drop.
  def handle_info({:llm_result, _ref, _}, state), do: {:noreply, state}

  # Tool task completed normally — `Task.Supervisor.async_nolink`
  # delivers the return value as `{ref, value}`.
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.tool_monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {{_task, tc, timer}, tool_monitors} ->
        Process.cancel_timer(timer)
        Process.demonitor(ref, [:flush])
        state = %{state | tool_monitors: tool_monitors}
        {:noreply, record_tool_done(state, tc.id, result)}
    end
  end

  def handle_info({:tool_timeout, ref}, state) do
    case Map.pop(state.tool_monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {{task, tc, _timer}, tool_monitors} ->
        _ = Task.shutdown(task, :brutal_kill)
        state = %{state | tool_monitors: tool_monitors}
        {:noreply, record_tool_done(state, tc.id, {synth_tool_timeout(tc), nil})}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{llm_monitor: ref} = state) do
    state = %{state | llm_ref: nil, llm_pid: nil, llm_monitor: nil}

    case reason do
      :normal -> {:noreply, state}
      _ -> {:noreply, handle_llm_result(state, {:error, {:llm_crash, reason}})}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.tool_monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {{_task, _tc, timer}, tool_monitors} when reason == :normal ->
        Process.cancel_timer(timer)
        {:noreply, %{state | tool_monitors: tool_monitors}}

      {{_task, tc, timer}, tool_monitors} ->
        Process.cancel_timer(timer)
        state = %{state | tool_monitors: tool_monitors}
        crash_result = synth_tool_crash(tc, reason)
        {:noreply, record_tool_done(state, tc.id, {crash_result, nil})}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    kill_subordinates(state)
    :ok
  end

  # ── Turn orchestration ───────────────────────────────────────────────

  defp start_turn(state, text, opts) do
    attachments = Keyword.get(opts, :attachments, [])

    alias_name =
      Keyword.get(opts, :llm_alias) || state.llm_alias || Agent.default_llm_alias()

    # Scope `:max_turns` to this message only: a one-off override on
    # message N must NOT leak into message N+1's cap. Reset to the
    # config default whenever no opt is supplied.
    max_turns =
      case Keyword.get(opts, :max_turns) do
        n when is_integer(n) and n > 0 -> n
        _ -> default_max_turns()
      end

    state = %{state | max_turns: max_turns}

    if is_nil(alias_name) do
      # No LLM configured — delegate to the echo fallback runner which owns
      # its own PubSub broadcasts and persistence. It is text-only, so any
      # :attachments are dropped in echo (demo) mode.
      Long.Agent.SessionRunner.send_user_message(state.session_id, text, opts)
      state
    else
      start_llm_turn(state, text, alias_name, attachments)
    end
  end

  defp start_llm_turn(state, text, alias_name, attachments) do
    broadcast(state.session_id, :loop_started)
    turn_no = state.turn + 1
    broadcast(state.session_id, {:turn_start, turn_no})

    user_msg = build_user_message(text, attachments)
    display_text = display_text_for(text, attachments)
    persist_message(state.session_id, :user, display_text, [], [], turn_no, attachment_blocks(attachments))

    %{system_addendum: summary_addendum, messages: history} =
      History.load_or_compress(state.session_id, alias_name)

    memory_addendum =
      text
      |> Recall.recall(session_id: state.session_id, limit: 8, bump: false)
      |> Recall.format_for_prompt()

    skill_block = SkillStore.list_names_for_prompt(Agent.member_id_for_session(state.session_id))
    addendum = merge_addenda([summary_addendum, memory_addendum, skill_block])

    tools = default_tools()

    # Prepend a flat tool inventory + mandate so the model's first
    # impression every turn is "these are my real tools" rather than
    # whatever it remembers from training. The system body itself
    # references `{{session_id}}` in GraphQL cheatsheet examples;
    # substitute the real id so the model can copy-paste directly.
    system_text =
      [
        Long.Agent.ToolInventory.render(tools),
        Loop.default_system() |> String.replace("{{session_id}}", state.session_id),
        addendum
      ]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join("\n\n")

    system_msg = ReqLLM.Context.system(system_text)
    btw_msgs = Enum.map(state.btws, &ReqLLM.Context.user("[note] " <> &1))
    messages = [system_msg | history] ++ [user_msg] ++ btw_msgs

    tool_ctx = %{session_id: state.session_id, workspace_root: workspace_root()}

    state =
      %{
        state
        | stage: :calling_llm,
          turn: turn_no,
          iteration: 1,
          compression_count: 0,
          messages: messages,
          tools: tools,
          tool_ctx: tool_ctx,
          llm_alias: alias_name,
          btws: [],
          tool_results: %{},
          pending_tool_calls: %{},
          tool_monitors: %{},
          current_request: short_request(display_text)
      }

    spawn_llm(state)
  end

  defp spawn_llm(state) do
    ref = make_ref()

    llm_opts =
      build_llm_callbacks(state.tools, state.tool_ctx)
      |> Keyword.put(:llm_alias, state.llm_alias)

    case state.llm_consumer.start(self(), ref, state.messages, state.tools, llm_opts) do
      {:ok, pid} ->
        mref = Process.monitor(pid)

        state =
          %{state | llm_ref: ref, llm_pid: pid, llm_monitor: mref, stage: :calling_llm}

        persist_snapshot(state)
        state

      {:error, reason} ->
        _ =
          ErrorTracker.report(
            %RuntimeError{message: "spawn_llm failed: #{inspect(reason)}"},
            [],
            %{source: "server.spawn_llm", session_id: state.session_id, turn: state.turn}
          )

        broadcast(state.session_id, {:loop_error, "spawn_llm: #{inspect(reason)}"})
        end_turn(idle(state), nil)
    end
  end

  defp handle_llm_result(state, {:ok, %{type: :final_answer, text: text}}) do
    assistant_msg = ReqLLM.Context.assistant(text || "")

    persist_message(state.session_id, :assistant, text || "", [], [], state.turn)

    state = %{state | messages: state.messages ++ [assistant_msg]} |> idle()
    end_turn(state, {:done, %{reason: :no_tool_call}})
  end

  defp handle_llm_result(state, {:ok, %{type: :tool_calls, tool_calls: tcs, text: text}}) do
    {to_run, overflow} = Enum.split(tcs, @max_tool_calls_per_turn)

    req_calls =
      Enum.map(tcs, fn tc ->
        ReqLLM.ToolCall.new(tc.id, tc.name, Jason.encode!(tc.arguments))
      end)

    assistant_msg = ReqLLM.Context.assistant(text || "", tool_calls: req_calls)

    # outbound_media_blocks stages any send_media output into web_inbox for
    # the web UI — the referenced file was produced on an earlier turn, so it
    # already exists on disk by now.
    persist_message(
      state.session_id,
      :assistant,
      text || "",
      tcs,
      [],
      state.turn,
      outbound_media_blocks(state.session_id, tcs)
    )

    # Synthesize tool_results immediately for the overflow tail; only
    # the to_run portion goes through actual execution.
    overflow_results =
      for tc <- overflow, into: %{} do
        {tc.id, skipped_tool_result(tc)}
      end

    pending = for tc <- to_run, into: %{}, do: {tc.id, tc}

    state =
      %{
        state
        | stage: :running_tools,
          pending_tool_calls: pending,
          tool_results: overflow_results,
          messages: state.messages ++ [assistant_msg]
      }

    persist_snapshot(state)
    spawn_tools(state, to_run)
  end

  defp handle_llm_result(state, {:error, exception}) do
    # LLMCall already reports on final retry failure with `source: "llm_call"`,
    # but it has no session context. Re-report here with session_id so
    # operators can correlate errors to a conversation in /errors.
    _ =
      ErrorTracker.report(
        normalize_error(exception),
        [],
        %{source: "server.llm_result", session_id: state.session_id, turn: state.turn}
      )

    msg = if is_exception(exception), do: Exception.message(exception), else: inspect(exception)
    broadcast(state.session_id, {:loop_error, msg})
    end_turn(idle(state), nil)
  end

  defp normalize_error(e) when is_exception(e), do: e

  defp normalize_error({tag, reason}) when is_atom(tag),
    do: %RuntimeError{message: "#{tag}: #{inspect(reason)}"}

  defp normalize_error(other), do: %RuntimeError{message: inspect(other)}

  defp spawn_tools(state, tool_calls) do
    tools_index = Map.new(state.tools, fn mod -> {mod.name(), mod} end)

    monitors =
      Enum.reduce(tool_calls, state.tool_monitors, fn tc, acc ->
        broadcast(
          state.session_id,
          {:tool_start, %{id: tc.id, name: tc.name, args: tc.arguments, index: 0, count: 1}}
        )

        task =
          Task.Supervisor.async_nolink(@task_sup, fn ->
            execute_tool(tc, tools_index, state.tool_ctx)
          end)

        timer = Process.send_after(self(), {:tool_timeout, task.ref}, tool_timeout_ms())
        Map.put(acc, task.ref, {task, tc, timer})
      end)

    %{state | tool_monitors: monitors}
  end

  defp record_tool_done(state, id, {req_message, ask_user_payload}) do
    name = tool_name(state, id)

    state = %{
      state
      | tool_results: Map.put(state.tool_results, id, req_message),
        pending_tool_calls: Map.delete(state.pending_tool_calls, id)
    }

    persist_message(state.session_id, :tool, "", [], [req_message], state.turn)

    broadcast(
      state.session_id,
      {:tool_done, %{id: id, name: name, data: tool_data_for_event(req_message), exit?: false}}
    )

    cond do
      ask_user_payload ->
        broadcast(
          state.session_id,
          {:ask_user,
           %{
             "question" => ask_user_payload[:question],
             "candidates" => ask_user_payload[:candidates] || []
           }}
        )

        state
        |> Map.put(:stage, :asked_user)
        |> Map.put(:current_request, nil)
        |> end_turn({:done, %{reason: :asked_user, data: ask_user_payload}})

      map_size(state.pending_tool_calls) == 0 ->
        advance_after_tool_batch(state)

      true ->
        state
    end
  end

  defp advance_after_tool_batch(state) do
    ordered_results =
      state.messages
      |> tool_call_order_in_last_assistant()
      |> Enum.map(&Map.fetch!(state.tool_results, &1))

    state = %{
      state
      | messages: state.messages ++ ordered_results,
        pending_tool_calls: %{},
        tool_results: %{},
        tool_monitors: %{}
    }

    if state.iteration >= state.max_turns do
      maybe_compress_and_continue(state)
    else
      broadcast(state.session_id, {:turn_start, state.turn + 1})
      spawn_llm(%{state | turn: state.turn + 1, iteration: state.iteration + 1})
    end
  end

  # Iteration budget exhausted. If we still have compression headroom,
  # fold the in-flight history into a summary and continue with a
  # smaller payload + reset iteration. Beyond `@max_in_flight_compressions`
  # we give up — likely a real loop, not just a long task.
  defp maybe_compress_and_continue(%{compression_count: n} = state)
       when n >= @max_in_flight_compressions do
    end_turn(idle(state), {:done, %{reason: :max_turns}})
  end

  defp maybe_compress_and_continue(state) do
    case compress_in_flight(state) do
      {:ok, compressed_state} ->
        broadcast(state.session_id, {:turn_start, state.turn + 1})

        spawn_llm(%{
          compressed_state
          | turn: state.turn + 1,
            iteration: 1,
            compression_count: state.compression_count + 1
        })

      {:error, reason} ->
        Logger.warning(
          "Long.Agent.Server: in-flight compression failed " <>
            "(session=#{state.session_id}, reason=#{inspect(reason)}); " <>
            "falling back to :max_turns end_turn"
        )

        end_turn(idle(state), {:done, %{reason: :max_turns}})
    end
  end

  # Build a row-shape list out of state.messages (the in-flight tail)
  # for the Summarizer, fold the older portion into a fresh summary,
  # and rebuild state.messages = [augmented_system, recent_tail].
  defp compress_in_flight(state) do
    case state.llm_alias || Agent.default_llm_alias() do
      nil -> {:error, :no_llm_alias}
      alias_name -> do_compress_in_flight(state, alias_name)
    end
  end

  defp do_compress_in_flight(state, alias_name) do
    {system_msg, body} = split_system(state.messages)
    {to_fold, tail} = split_at_recent_tool_pair(body)

    if to_fold == [] do
      {:error, :nothing_to_fold}
    else
      rows = Enum.map(to_fold, &req_message_to_row/1)

      case summarizer().(nil, rows, alias_name) do
        {:ok, summary} ->
          new_system = augment_system_with_summary(system_msg, summary)
          {:ok, %{state | messages: [new_system | tail]}}

        err ->
          err
      end
    end
  end

  # Injectable for tests so they don't hit a real LLM.
  defp summarizer,
    do: Application.get_env(:long, :summarizer, &Long.Jido.Summarizer.summarize/3)

  defp split_system([%ReqLLM.Message{role: :system} = sys | rest]), do: {sys, rest}
  defp split_system(msgs), do: {nil, msgs}

  # Keep the last assistant message that issued tool_calls + its
  # following tool_results. Everything earlier gets summarised. If
  # there's no such anchor (no tools yet this turn) keep the tail
  # half — better than dropping context blind.
  defp split_at_recent_tool_pair(msgs) do
    case last_tool_call_index(msgs) do
      nil ->
        mid = div(length(msgs), 2)
        Enum.split(msgs, mid)

      idx ->
        Enum.split(msgs, idx)
    end
  end

  defp last_tool_call_index(msgs) do
    msgs
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%ReqLLM.Message{role: :assistant, tool_calls: [_ | _]}, i} -> i
      _ -> false
    end)
  end

  defp augment_system_with_summary(nil, summary) do
    ReqLLM.Context.system("## Compressed earlier turns\n\n" <> summary)
  end

  defp augment_system_with_summary(%ReqLLM.Message{content: parts}, summary) do
    text = extract_text(parts)

    ReqLLM.Context.system(
      text <> "\n\n## Compressed earlier turns\n\n" <> summary
    )
  end

  # ReqLLM.Message → DB-row-shaped map that `Long.Jido.Summarizer`
  # consumes. The shape mirrors what `persist_message/6` writes to
  # `Long.Agent.Message`, with string keys on tool_calls/tool_results.
  # The `:tool` clause re-keys to `role: :user` so the Summarizer's
  # `[tool_result]` render branch fires (it pattern-matches on
  # `role: :user` + non-empty `tool_results`).
  defp req_message_to_row(%ReqLLM.Message{role: :assistant, content: parts, tool_calls: calls}) do
    %{
      role: :assistant,
      content: extract_text(parts),
      tool_calls:
        Enum.map(calls || [], fn tc ->
          %{
            "id" => tc.id,
            "name" => ReqLLM.ToolCall.name(tc),
            "input" => ReqLLM.ToolCall.args_map(tc) || %{}
          }
        end),
      tool_results: []
    }
  end

  defp req_message_to_row(%ReqLLM.Message{role: :tool, tool_call_id: id, content: parts}) do
    %{
      role: :user,
      content: "",
      tool_calls: [],
      tool_results: [%{"tool_use_id" => id, "content" => extract_text(parts)}]
    }
  end

  defp req_message_to_row(%ReqLLM.Message{role: role, content: parts}) do
    %{role: role, content: extract_text(parts), tool_calls: [], tool_results: []}
  end

  defp idle(state), do: %{state | stage: :idle, current_request: nil}

  # Persist snapshot BEFORE `:loop_ended` so any subscriber reading the
  # snapshot post-broadcast sees the final state. Caller is responsible
  # for setting `:stage` (typically via `idle/1`, except `:asked_user`).
  defp end_turn(state, reason) do
    persist_snapshot(state)
    if reason, do: broadcast(state.session_id, reason)
    broadcast(state.session_id, :loop_ended)
    finish_turn(state)
  end

  defp finish_turn(state) do
    if state.turn == 1 and title_unset?(state.session) do
      _ = Long.Jido.TitleGen.maybe_generate_async(state.session_id, state.llm_alias)
    end

    drain_inbox(state)
  end

  defp title_unset?(%{title: "untitled"}), do: true
  defp title_unset?(_), do: false

  defp drain_inbox(state) do
    case :queue.out(state.inbox) do
      {{:value, {text, opts}}, q} when state.stage == :idle ->
        state = %{state | inbox: q}
        start_turn(state, text, opts)

      _ ->
        state
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp kill_subordinates(state) do
    if state.llm_monitor, do: Process.demonitor(state.llm_monitor, [:flush])
    if is_pid(state.llm_pid), do: Process.exit(state.llm_pid, :kill)

    Enum.each(state.tool_monitors, fn {_ref, {task, _tc, timer}} ->
      Process.cancel_timer(timer)
      _ = Task.shutdown(task, :brutal_kill)
    end)

    :ok
  end

  defp demonitor_llm(%{llm_monitor: nil} = state), do: state

  defp demonitor_llm(state) do
    Process.demonitor(state.llm_monitor, [:flush])
    %{state | llm_ref: nil, llm_pid: nil, llm_monitor: nil}
  end

  defp execute_tool(%{id: id, name: name, arguments: args}, tools_index, tool_ctx) do
    mod = Map.get(tools_index, name)

    result =
      if is_nil(mod) do
        {:error, "unknown tool: #{name}"}
      else
        Jido.Exec.run(mod, safe_atomize_keys(args), tool_ctx)
      end

    ask =
      case result do
        {:ok, %{ask_user: true} = payload} -> payload
        _ -> nil
      end

    {ReqLLM.Context.tool_result(id, format_result(result)), ask}
  end

  defp safe_atomize_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {k, v}, acc when is_binary(k) ->
        try do
          Map.put(acc, String.to_existing_atom(k), v)
        rescue
          ArgumentError -> acc
        end

      {k, v}, acc ->
        Map.put(acc, k, v)
    end)
  end

  defp safe_atomize_keys(other), do: other

  defp format_result({:ok, payload}) when is_map(payload),
    do: payload |> Long.Util.Utf8.sanitize() |> Jason.encode!()

  defp format_result({:ok, payload}), do: inspect(payload)

  defp format_result({:error, e}) when is_binary(e),
    do: Jason.encode!(%{error: Long.Util.Utf8.sanitize(e)})

  defp format_result({:error, e}), do: Jason.encode!(%{error: inspect(e)})

  defp skipped_tool_result(tc) do
    synth_error_result(tc, %{
      error: "skipped",
      reason:
        "Too many tool_calls in this turn (cap = #{@max_tool_calls_per_turn}). " <>
          "Issue this call again in the next turn.",
      tool_name: tc.name
    })
  end

  defp synth_tool_crash(tc, reason),
    do: synth_error_result(tc, %{error: "tool execution exited: #{inspect(reason)}"})

  defp synth_tool_timeout(tc),
    do:
      synth_error_result(tc, %{
        error: "tool execution timed out after #{tool_timeout_ms()}ms"
      })

  defp synth_error_result(tc, payload),
    do: ReqLLM.Context.tool_result(tc.id, Jason.encode!(payload))

  defp tool_timeout_ms,
    do: Application.get_env(:long, :tool_timeout_ms, @default_tool_timeout_ms)

  defp build_user_message(text, []), do: ReqLLM.Context.user(text)

  defp build_user_message(text, attachments) do
    image_parts =
      attachments
      |> Enum.filter(&image?/1)
      |> Enum.flat_map(fn path ->
        case File.read(path) do
          {:ok, bytes} -> [ReqLLM.Message.ContentPart.image(bytes, mime_for(path))]
          _ -> []
        end
      end)

    body = text_with_file_note(text || "", attachments)

    case image_parts do
      [] -> ReqLLM.Context.user(body)
      parts -> ReqLLM.Context.user([ReqLLM.Message.ContentPart.text(body) | parts])
    end
  end

  # Non-image uploads aren't multimodal — tell the model their workspace
  # paths so it can open them with file_read.
  defp text_with_file_note(text, attachments) do
    case Enum.reject(attachments, &image?/1) do
      [] -> text
      files -> "#{text}\n\n[Uploaded files — open with file_read:\n#{Enum.map_join(files, "\n", &("- " <> &1))}]"
    end
  end

  defp display_text_for(text, []), do: text

  defp display_text_for(text, attachments) do
    names = Enum.map_join(attachments, ", ", &Path.basename/1)
    "#{text}\n[attachments: #{names}]"
  end

  # Persist a lightweight reference to each upload on the user message so
  # the web UI can render it and history survives a reload. The bytes stay
  # on the workspace filesystem; only {file, kind} is stored.
  defp attachment_blocks([]), do: %{}

  defp attachment_blocks(attachments) do
    %{
      "attachments" =>
        Enum.map(attachments, fn p ->
          %{"file" => Path.basename(p), "kind" => if(image?(p), do: "image", else: "file")}
        end)
    }
  end

  # When the assistant calls send_media, copy the referenced workspace file
  # into the session's web_inbox and record a UI ref on the message, so the
  # web /chat renders it inline (bot channels deliver the same payload via the
  # :bot_send_media broadcast; the web surfaces it from message.blocks). The
  # file already exists — send_media targets a path the agent produced earlier.
  defp outbound_media_blocks(session_id, tool_calls) do
    case Enum.flat_map(tool_calls, &outbound_media(session_id, &1)) do
      [] -> %{}
      medias -> %{"attachments" => medias}
    end
  end

  defp outbound_media(session_id, %{name: "send_media", arguments: args}) when is_map(args) do
    path = args["path"]

    if is_binary(path) and File.regular?(path) do
      dest = Agent.stage_in_web_inbox(session_id, path)

      [
        %{
          "file" => Path.basename(dest),
          "kind" => to_string(args["kind"] || "file"),
          "caption" => args["caption"]
        }
      ]
    else
      # Not on disk yet (e.g. generated in this same tool batch) — the bot
      # broadcast path catches it post-turn; the web render skips it.
      Logger.debug("send_media path not ready at persist time, skipping web render: #{inspect(path)}")
      []
    end
  end

  defp outbound_media(_session_id, _tool_call), do: []

  defp image?(p), do: Agent.image?(p)

  @mime_by_ext %{
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".png" => "image/png",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".bmp" => "image/bmp"
  }
  defp mime_for(p), do: Map.get(@mime_by_ext, p |> Path.extname() |> String.downcase(), "application/octet-stream")

  defp short_request(text) do
    text
    |> Long.Util.Text.first_line()
    |> Long.Util.Text.preview(40)
  end

  defp merge_addenda(parts) when is_list(parts) do
    parts
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> case do
      [] -> nil
      cleaned -> Enum.join(cleaned, "\n\n")
    end
  end

  defp default_tools do
    Application.get_env(:long, :default_tools, Long.Jido.SessionRunner.default_tools())
  end

  defp workspace_root, do: Agent.workspace_root()

  defp build_llm_callbacks(tools, tool_ctx) do
    callbacks =
      Map.new(tools, fn mod ->
        {mod.name(), fn args -> Jido.Exec.run(mod, args, tool_ctx) end}
      end)

    [tool_callbacks: callbacks]
  end

  defp tool_name(state, id) do
    case Map.get(state.pending_tool_calls, id) do
      %{name: name} -> name
      _ -> nil
    end
  end

  # `ReqLLM.Context.tool_result/2` wraps the result string as a `:text`
  # ContentPart, not `:tool_result`; we match both so synthesised error
  # results (crash/timeout/skipped) still surface in the PubSub event.
  defp tool_data_for_event(%ReqLLM.Message{content: parts}) when is_list(parts) do
    Enum.find_value(parts, fn
      %{type: :text, text: t} -> decode_or_text(t)
      %{type: :tool_result, output: o} -> decode_or_text(o)
      _ -> nil
    end)
  end

  defp tool_data_for_event(_), do: nil

  defp decode_or_text(s) do
    case Jason.decode(to_string(s)) do
      {:ok, decoded} -> decoded
      _ -> to_string(s)
    end
  end

  defp tool_call_order_in_last_assistant(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value([], fn
      %ReqLLM.Message{role: :assistant, tool_calls: calls} when is_list(calls) and calls != [] ->
        Enum.map(calls, & &1.id)

      _ ->
        nil
    end)
  end

  # ── PubSub / persistence ─────────────────────────────────────────────

  defp broadcast(session_id, msg) do
    Phoenix.PubSub.broadcast(Long.PubSub, @topic_prefix <> session_id, msg)
  end

  defp persist_message(session_id, role, content, tool_calls, tool_results, turn, blocks \\ %{}) do
    tcs =
      Enum.map(tool_calls, fn tc ->
        %{"id" => tc.id, "name" => tc.name, "input" => tc.arguments}
      end)

    trs =
      Enum.map(tool_results, fn msg ->
        %{
          "tool_use_id" => msg.tool_call_id,
          "content" => extract_text(msg.content)
        }
      end)

    attrs = %{
      session_id: session_id,
      role: role,
      content: content,
      tool_calls: tcs,
      tool_results: trs,
      turn: turn,
      blocks: blocks
    }

    case Agent.append_message(attrs) do
      {:ok, row} ->
        broadcast(session_id, {:message_persisted, %{message: row}})

      other ->
        Logger.error(
          "Long.Agent.Server: persist message failed (session=#{session_id}, role=#{inspect(role)}, turn=#{turn}): #{inspect(other)}"
        )
    end
  end

  defp extract_text(parts) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{type: :text, text: t} -> t
      %{type: :tool_result, output: o} -> to_string(o)
      %{"type" => "text", "text" => t} -> t
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  defp extract_text(text) when is_binary(text), do: text
  defp extract_text(_), do: ""

  defp persist_snapshot(state) do
    attrs = %{
      session_id: state.session_id,
      turn: state.turn,
      stage: state.stage,
      messages_json: encode_term(state.messages),
      pending_tool_calls_json: encode_term(state.pending_tool_calls),
      tool_results_json: encode_term(state.tool_results),
      last_assistant_text: last_assistant_text(state.messages),
      llm_alias: state.llm_alias
    }

    case Agent.upsert_turn_snapshot(attrs) do
      {:ok, _} ->
        :ok

      err ->
        Logger.warning("Long.Agent.Server: snapshot persist failed: #{inspect(err)}")
    end
  end

  defp last_assistant_text(messages) do
    Enum.find_value(Enum.reverse(messages), nil, fn
      %ReqLLM.Message{role: :assistant, content: parts} -> extract_text(parts)
      _ -> nil
    end)
  end

  # ReqLLM messages contain non-JSON-friendly structs (tool calls,
  # content parts); fall back to term_to_binary + Base64.
  defp encode_term(term) do
    term
    |> :erlang.term_to_binary([:compressed])
    |> Base.encode64()
  end

  defp decode_term(nil), do: nil
  defp decode_term(""), do: nil

  defp decode_term(binary) when is_binary(binary) do
    Base.decode64!(binary) |> :erlang.binary_to_term([:safe])
  rescue
    _ -> nil
  end

  defp restore_from_snapshot(state, snap) do
    state = %{
      state
      | turn: snap.turn,
        stage: snap.stage,
        messages: decode_term(snap.messages_json) || [],
        pending_tool_calls: decode_term(snap.pending_tool_calls_json) || %{},
        tool_results: decode_term(snap.tool_results_json) || %{},
        llm_alias: snap.llm_alias || state.llm_alias
    }

    case snap.stage do
      :calling_llm ->
        # We were waiting on an LLM result — spawn a fresh consumer
        # with the same messages.
        spawn_llm(state)

      :running_tools ->
        # Some tools were in-flight; we don't know which ones the
        # crashed process had already gotten. Re-dispatch every
        # pending tool_call. Already-finished ones live in
        # `tool_results` and stay put.
        pending = Map.values(state.pending_tool_calls)
        spawn_tools(state, pending)

      _ ->
        state
    end
  end

  defp public_snapshot(state) do
    %{
      stage: state.stage,
      turn: state.turn,
      max_turns: state.max_turns,
      current_request: state.current_request,
      pending_tool_count: map_size(state.pending_tool_calls),
      btw_count: length(state.btws),
      llm_alias: state.llm_alias
    }
  end
end
