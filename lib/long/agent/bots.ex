defmodule Long.Agent.Bots do
  @moduledoc """
  Phase 7 — generic bridge between an external chat platform and
  `Long.Agent.SessionRunner`. Every adapter (Telegram / Feishu / …) calls:

      Bots.run_and_collect(platform, external_id, text, opts)

  which:

  1. Resolves (or creates) the `BotUser` and its current session.
  2. Subscribes the calling process to the session's PubSub topic.
  3. Calls `SessionRunner.send_user_message/3`.
  4. Drives the event stream until `:loop_ended`, accumulating assistant
     text, tool-call summaries and ask-user prompts.
  5. Returns `{:ok, %{text: ..., tool_calls: [...], ask: nil | %{...}}}`
     ready for the adapter to render and ship back.

  ## Options

  - `:timeout` — max ms to wait for the loop to finish (default 600_000 / 10 min).
    Sized to cover a ~20-turn ReAct loop hitting `dispatch_per_tool_timeout_ms`
    on a few of those turns. Shorter timeouts silently drop replies — the
    agent keeps running and persists the final assistant message, but
    the bot worker has already given up and won't push it back.
  - `:on_delta` — `fn binary -> :ok end` called with each `:llm_chunk`,
    useful for adapters that support streaming UIs
  - `:on_tool_start` — `fn %{name, args, id} -> :ok end`
  - `:on_tool_done` — `fn %{name, data, id} -> :ok end`
  - `:chat_id`, `:display_name`, `:metadata` — merged into the BotUser row
    on first contact (or `update`d on subsequent contacts)
  - `:session_title` — title for the auto-created session
  """

  require Logger
  require Ash.Query

  alias Long.Agent
  alias Long.Agent.Activity
  alias Long.SessionRunner

  @default_timeout 120_000

  # Generous wall-clock cap for `run_async` watchers. 1 hour is much
  # longer than any realistic agent run; serves only as a safety net
  # for stuck loops / dead LLM connections that never broadcast
  # `:loop_ended`. Operators can override per-call via opts.
  @default_async_timeout 60 * 60 * 1_000

  @task_sup Long.Agent.TaskSup

  # Codepoint cap for the user-request preview shown in `/status` /
  # `agent_status`. ~40 chars fits one bot-message line on a phone.
  @request_preview_chars 40

  def run_and_collect(platform, external_id, text, opts \\ []) do
    with {:ok, %{session_id: session_id}} <- ensure_session(platform, external_id, opts) do
      run_on_session(session_id, text, opts)
    end
  end

  @doc """
  Fire-and-forget version of `run_and_collect/4`. The caller (a
  platform Worker handling an inbound message) isn't blocked on agent
  runtime; `:on_complete` (required) is called exactly once, even on
  `:loop_error` / `:timeout`, so platforms can always push something
  back.

  Three inline magic commands short-circuit the agent loop entirely:

    * `/clear` — wipe history + summary + checkpoint + session memories
    * `/status` — render the current `Activity.snapshot/1`
    * `/btw <note>` — append a mid-flight context note for the running
      agent (picked up via `Long.Jido.Loop`'s `inject_btws/1`)

  Returns `{:ok, %{bot_user, session_id, mode}}` where `mode` is one of
  `:cleared | :status | :btw | :dispatched`, or `{:error, reason}` if
  session resolution / task spawn failed. (Acquire-vs-enqueue happens
  inside the watcher task, so callers see `:dispatched` either way.)
  """
  def run_async(platform, external_id, text, opts \\ []) do
    on_complete = Keyword.fetch!(opts, :on_complete)
    watcher_opts = Keyword.put_new(opts, :timeout, @default_async_timeout)

    with {:ok, %{session_id: session_id, bot_user: user}} <-
           ensure_session(platform, external_id, opts) do
      case parse_magic(text) do
        :clear ->
          clear_session(session_id)
          on_complete.(user, {:ok, ack("已清空这条会话的历史、摘要、检查点和 session 记忆。可以重新开始了。")})
          {:ok, %{bot_user: user, session_id: session_id, mode: :cleared}}

        :status ->
          on_complete.(user, {:ok, ack(render_status(Activity.snapshot(session_id)))})
          {:ok, %{bot_user: user, session_id: session_id, mode: :status}}

        {:btw, note} ->
          Activity.add_btw(session_id, note)
          on_complete.(user, {:ok, ack("好的,已经加入到当前任务的上下文里。")})
          {:ok, %{bot_user: user, session_id: session_id, mode: :btw}}

        :normal ->
          dispatch_message(user, session_id, text, watcher_opts, on_complete)
      end
    end
  end

  # Recognised inline commands. `/clear` and `/status` are nullary
  # (exact match after trim); `/btw <note>` carries a payload.
  defp parse_magic(text) when is_binary(text) do
    case String.trim(text) do
      "/clear" -> :clear
      "/status" -> :status
      "/btw " <> note -> {:btw, String.trim(note)}
      _ -> :normal
    end
  end

  defp parse_magic(_), do: :normal

  defp ack(text) do
    %{text: text, tool_calls: [], attachments: [], ask: nil, error: nil}
  end

  # Kill the watcher + wipe DB on a background task so the user gets
  # the ack immediately. `Task.Supervisor.terminate_child` is
  # synchronous and can block up to 5s waiting for the child to honor
  # `:shutdown` (e.g. blocked on Finch); we don't want that on the ack
  # path. Activity is cleared *synchronously* before backgrounding so
  # any racing inbound after the ack sees an idle session. `session_id`
  # stays the same — same WeChat thread / chat URL — just empty.
  defp clear_session(session_id) do
    {prior_owner_pid, _} = Activity.clear(session_id)

    # Kill in-flight LLM/tool tasks and drop the persisted snapshot
    # before wiping DB rows underneath the running Server.
    Long.Agent.Server.terminate_session(session_id)

    Task.Supervisor.start_child(@task_sup, fn ->
      if is_pid(prior_owner_pid) do
        _ = Task.Supervisor.terminate_child(@task_sup, prior_owner_pid)
      end

      wipe_session_rows(session_id)
    end)

    :ok
  end

  defp wipe_session_rows(session_id) do
    _ =
      Long.Agent.Message
      |> Ash.Query.filter(session_id == ^session_id)
      |> Ash.bulk_destroy(:destroy, %{}, strategy: :stream, return_errors?: false)

    _ =
      Long.Agent.SessionMemory
      |> Ash.Query.filter(session_id == ^session_id)
      |> Ash.bulk_destroy(:destroy, %{}, strategy: :stream, return_errors?: false)

    case Agent.get_checkpoint(session_id) do
      {:ok, checkpoint} -> Ash.destroy(checkpoint)
      _ -> :ok
    end

    with {:ok, session} <- Agent.get_session(session_id) do
      Agent.update_session(session, %{summary: nil, summary_through_inserted_at: nil})
    end
  end

  defp render_status(%{owner: nil, queue_length: 0, pending_btws: 0}),
    do: "空闲,没有任务在跑。"

  defp render_status(%{owner: nil, queue_length: q, pending_btws: b}),
    do: "空闲,但还有 #{q} 条排队消息和 #{b} 条补充。(异常状态,通常 watcher 会立刻接力)"

  defp render_status(%{owner: info, queue_length: q, pending_btws: b}) do
    base = Activity.describe(info)
    extras = [
      q > 0 && "排队中 #{q} 条",
      b > 0 && "补充 #{b} 条"
    ] |> Enum.filter(& &1) |> Enum.join(" · ")

    if extras == "", do: base, else: base <> " · " <> extras
  end

  # Watcher Task decides acquire-vs-enqueue from inside itself, so the
  # pid Activity registers is the watcher's own (long-lived) pid, not
  # the inbound handler's (which exits right after `run_async` returns
  # and would trigger an immediate DOWN that drops the owner record
  # mid-run).
  defp dispatch_message(user, session_id, text, watcher_opts, on_complete) do
    case Task.Supervisor.start_child(@task_sup, fn ->
           acquire_or_enqueue(user, session_id, text, watcher_opts, on_complete)
         end) do
      {:ok, _pid} -> {:ok, %{bot_user: user, session_id: session_id, mode: :dispatched}}
      {:error, reason} -> {:error, {:task_start_failed, reason}}
    end
  end

  defp acquire_or_enqueue(user, session_id, text, watcher_opts, on_complete) do
    payload = {user, text, on_complete}

    case Activity.try_acquire_or_enqueue(session_id, payload) do
      :acquired ->
        Activity.update(session_id, %{request: short_request(text)})
        watcher_run(user, session_id, text, watcher_opts, on_complete)

      :enqueued ->
        # Exit immediately; the current owner's `drain_queue/2` will
        # pop our payload and invoke the closure with the agent's
        # result when it's our turn.
        on_complete.(user, {:ok, ack("收到,前一条还在处理中,跑完后立刻处理你这条。")})
    end
  end

  defp short_request(text) when is_binary(text) do
    text |> Long.Util.Text.first_line() |> Long.Util.Text.preview(@request_preview_chars)
  end

  defp short_request(_), do: nil

  # Watcher owns the slot. Processes the first message, then drains the
  # queue (still under the same slot) until empty before releasing.
  defp watcher_run(user, session_id, text, watcher_opts, on_complete) do
    try do
      process_one(user, session_id, text, watcher_opts, on_complete)
      drain_queue(session_id, watcher_opts)
    rescue
      e ->
        report_crash(e, __STACKTRACE__, session_id)
        on_complete.(user, {:error, e})
    catch
      kind, reason ->
        report_crash({kind, reason}, __STACKTRACE__, session_id)
        on_complete.(user, {:error, {kind, reason}})
    after
      Activity.release(session_id)
    end
  end

  defp drain_queue(session_id, watcher_opts) do
    case Activity.dequeue(session_id) do
      nil ->
        :ok

      {next_user, next_text, next_on_complete} ->
        # Refresh `:request` (and clear stale tool/turn from the previous
        # message) so `/status` reflects what we're working on right now.
        Activity.update(session_id, %{
          request: short_request(next_text),
          turn: nil,
          tool: nil
        })

        process_one(next_user, session_id, next_text, watcher_opts, next_on_complete)
        drain_queue(session_id, watcher_opts)
    end
  end

  defp process_one(user, session_id, text, watcher_opts, on_complete) do
    result = run_on_session(session_id, text, watcher_opts)
    on_complete.(user, result)
  end

  defp report_crash(error, stacktrace, session_id) do
    Logger.error(
      "Bots.run_async watcher crashed (session_id=#{session_id}): #{inspect(error)}"
    )

    _ = ErrorTracker.report(error, stacktrace, %{session_id: session_id, source: "bots.run_async"})
  end

  @doc """
  Drive an existing session synchronously: subscribe to its PubSub topic,
  fire `text` as a user message, accumulate the loop's events, and return
  `{:ok, %{text, tool_calls, attachments, ask, error}}` once `:loop_ended`
  arrives.

  Use this when you already know the `session_id` (e.g. a scheduled
  task triggering its own session) and don't need the
  platform/external_id lookup in `run_and_collect/4`.
  """
  def run_on_session(session_id, text, opts \\ []) when is_binary(session_id) do
    :ok = SessionRunner.subscribe(session_id)

    try do
      :ok =
        SessionRunner.send_user_message(
          session_id,
          text,
          Keyword.take(opts, [:attachments])
        )

      collect(session_id, opts)
    after
      SessionRunner.unsubscribe(session_id)
    end
  end

  @doc """
  Find-or-create the BotUser row and its current session. Updates
  `chat_id` / `display_name` / `metadata` on every call so the row stays
  fresh as the user's platform profile evolves.
  """
  def ensure_session(platform, external_id, opts \\ []) do
    case find_bot_user(platform, external_id) do
      nil -> create_bot_user_and_session(platform, external_id, opts)
      user -> refresh_existing(user, opts)
    end
  end

  defp find_bot_user(platform, external_id) do
    case Agent.list_bot_users() do
      {:ok, all} ->
        Enum.find(all, fn b -> b.platform == platform and b.external_id == external_id end)

      _ ->
        nil
    end
  end

  defp create_bot_user_and_session(platform, external_id, opts) do
    title = Keyword.get(opts, :session_title, "#{platform}:#{external_id}")
    llm_alias = Keyword.get(opts, :llm_alias) || default_llm_alias()

    with {:ok, session} <- Agent.start_session(%{title: title, llm_alias: llm_alias}),
         {:ok, user} <-
           Agent.create_bot_user(%{
             platform: platform,
             external_id: external_id,
             chat_id: Keyword.get(opts, :chat_id),
             display_name: Keyword.get(opts, :display_name),
             session_id: session.id,
             metadata: Keyword.get(opts, :metadata, %{})
           }) do
      {:ok, %{bot_user: user, session_id: session.id}}
    end
  end

  # Bot-created sessions have no human in the loop to pick an LLM; fall
  # back to whichever LLMConfig row was registered first so we don't
  # land in the Echo-fallback path the dispatcher uses for nil aliases.
  defp default_llm_alias do
    case Agent.list_llms() do
      {:ok, [%{alias: a} | _]} -> a
      _ -> nil
    end
  end

  defp refresh_existing(user, opts) do
    needs_update? =
      maybe_field(opts, :chat_id, user.chat_id) ||
        maybe_field(opts, :display_name, user.display_name) ||
        maybe_field(opts, :metadata, user.metadata)

    with {:ok, user} <- maybe_apply_update(user, opts, needs_update?) do
      attach_session(user)
    end
  end

  defp maybe_apply_update(user, _opts, false), do: {:ok, user}

  defp maybe_apply_update(user, opts, true) do
    Agent.update_bot_user(user, %{
      chat_id: Keyword.get(opts, :chat_id, user.chat_id),
      display_name: Keyword.get(opts, :display_name, user.display_name),
      metadata: Map.merge(user.metadata || %{}, Keyword.get(opts, :metadata, %{}))
    })
  end

  defp attach_session(%{session_id: nil} = user) do
    with {:ok, session} <-
           Agent.start_session(%{
             title: "#{user.platform}:#{user.external_id}",
             llm_alias: Agent.default_llm_alias()
           }),
         {:ok, user} <- Agent.rotate_bot_session(user, %{session_id: session.id}) do
      {:ok, %{bot_user: user, session_id: session.id}}
    end
  end

  defp attach_session(user), do: {:ok, %{bot_user: user, session_id: user.session_id}}

  defp maybe_field(opts, key, current) do
    case Keyword.fetch(opts, key) do
      {:ok, val} when val != current -> true
      _ -> false
    end
  end

  # ── Event collection ─────────────────────────────────────────────────────

  defp collect(session_id, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    deadline =
      case timeout do
        :infinity -> :infinity
        ms when is_integer(ms) -> System.monotonic_time(:millisecond) + ms
      end

    do_collect(
      %{
        session_id: session_id,
        on_delta: Keyword.get(opts, :on_delta),
        on_tool_start: Keyword.get(opts, :on_tool_start),
        on_tool_done: Keyword.get(opts, :on_tool_done),
        text: "",
        tool_calls: [],
        attachments: [],
        ask: nil,
        error: nil
      },
      deadline
    )
  end

  defp do_collect(state, deadline) do
    remaining =
      case deadline do
        :infinity -> :infinity
        ms -> max(0, ms - System.monotonic_time(:millisecond))
      end

    receive do
      :loop_ended ->
        {:ok, state |> apply_error_fallback() |> Map.take([:text, :tool_calls, :attachments, :ask, :error])}

      {:bot_send_media, payload} ->
        do_collect(%{state | attachments: state.attachments ++ [payload]}, deadline)

      {:llm_chunk, t} ->
        if state.on_delta, do: state.on_delta.(t)
        do_collect(%{state | text: state.text <> t}, deadline)

      # The jido runner doesn't emit `:llm_chunk` (its ReqLLM stream is
      # drained with `classify/1` in one shot). It only emits the final
      # assistant message via `:message_persisted`. Take the last
      # non-empty assistant content as the reply; intermediate
      # assistant rows with only tool_calls have empty content and are
      # skipped.
      {:message_persisted, %{message: %{role: :assistant, content: c}}}
      when is_binary(c) and c != "" ->
        do_collect(%{state | text: c}, deadline)

      {:tool_start, %{id: id, name: name, args: args}} ->
        if state.on_tool_start, do: state.on_tool_start.(%{id: id, name: name, args: args})
        Activity.update(state.session_id, %{tool: name, tool_args: args})

        do_collect(
          %{state | tool_calls: state.tool_calls ++ [%{id: id, name: name, args: args}]},
          deadline
        )

      {:tool_done, %{id: id, name: name, data: data}} ->
        if state.on_tool_done, do: state.on_tool_done.(%{id: id, name: name, data: data})
        Activity.update(state.session_id, %{tool: nil, tool_args: nil})
        do_collect(state, deadline)

      {:turn_start, n} ->
        Activity.update(state.session_id, %{turn: n})
        do_collect(state, deadline)

      {:ask_user, payload} ->
        do_collect(%{state | ask: payload}, deadline)

      {:loop_error, msg} ->
        do_collect(%{state | error: msg}, deadline)

      # When Loop returns gracefully with `:error` (e.g. LLMCall
      # rescued and returned `{:error, _}` rather than raising),
      # session_runner emits `:done` with reason details but never
      # `:loop_error`. Capture the exception from `:done` so the
      # watcher's `on_complete` gets it in `result.error` and
      # platforms can render a meaningful reply.
      {:done, %{reason: :error, error: e}} ->
        do_collect(%{state | error: e}, deadline)

      {:done, _other_reason} ->
        do_collect(state, deadline)

      _other ->
        do_collect(state, deadline)
    after
      remaining -> {:error, :timeout}
    end
  end

  # When the loop ended with `:error` and no assistant text was
  # produced, synthesize a friendly fallback so platforms (which
  # render `result.text`) don't push an empty reply.
  defp apply_error_fallback(%{error: nil} = state), do: state
  defp apply_error_fallback(%{text: t} = state) when is_binary(t) and t != "", do: state

  defp apply_error_fallback(%{error: err} = state) do
    %{state | text: "出错了:" <> Long.Util.Error.humanize(err)}
  end

  @doc "Convenience that walks `tool_calls` into a one-line summary."
  def summarize_tool_calls([]), do: ""

  def summarize_tool_calls(calls) when is_list(calls) do
    calls
    |> Enum.map(fn %{name: n} -> "🛠 #{n}" end)
    |> Enum.join(" · ")
  end
end
