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

  - `:timeout` — max ms to wait for the loop to finish (default 120_000)
  - `:on_delta` — `fn binary -> :ok end` called with each `:llm_chunk`,
    useful for adapters that support streaming UIs
  - `:on_tool_start` — `fn %{name, args, id} -> :ok end`
  - `:on_tool_done` — `fn %{name, data, id} -> :ok end`
  - `:chat_id`, `:display_name`, `:metadata` — merged into the BotUser row
    on first contact (or `update`d on subsequent contacts)
  - `:session_title` — title for the auto-created session
  """

  alias Long.Agent
  alias Long.SessionRunner

  @default_timeout 120_000

  def run_and_collect(platform, external_id, text, opts \\ []) do
    with {:ok, %{session_id: session_id}} <- ensure_session(platform, external_id, opts) do
      run_on_session(session_id, text, opts)
    end
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
      {:ok, _pid} =
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
           Agent.start_session(%{title: "#{user.platform}:#{user.external_id}"}),
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
    deadline = System.monotonic_time(:millisecond) + timeout

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
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      :loop_ended ->
        {:ok, Map.take(state, [:text, :tool_calls, :attachments, :ask, :error])}

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

        do_collect(
          %{state | tool_calls: state.tool_calls ++ [%{id: id, name: name, args: args}]},
          deadline
        )

      {:tool_done, %{id: id, name: name, data: data}} ->
        if state.on_tool_done, do: state.on_tool_done.(%{id: id, name: name, data: data})
        do_collect(state, deadline)

      {:ask_user, payload} ->
        do_collect(%{state | ask: payload}, deadline)

      {:loop_error, msg} ->
        do_collect(%{state | error: msg}, deadline)

      _other ->
        do_collect(state, deadline)
    after
      remaining -> {:error, :timeout}
    end
  end

  @doc "Convenience that walks `tool_calls` into a one-line summary."
  def summarize_tool_calls([]), do: ""

  def summarize_tool_calls(calls) when is_list(calls) do
    calls
    |> Enum.map(fn %{name: n} -> "🛠 #{n}" end)
    |> Enum.join(" · ")
  end
end
