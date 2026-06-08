defmodule Long.Agent.Bots.Telegram do
  @moduledoc """
  Telegram bot adapter. Long-polls `https://api.telegram.org/bot<TOKEN>/`
  for incoming messages, fans them out to `Long.Agent.Bots.run_and_collect/4`,
  and posts the resulting assistant text back via `sendMessage`.

  Token resolution (see `Long.Agent.Bots.Telegram.Credential.load/0`):

    1. Enabled `Long.Agent.TelegramCredential` row → use its `bot_token`
    2. `TELEGRAM_BOT_TOKEN` env var (legacy fallback)
    3. None → worker stays idle until `reload/0` finds one

  The worker always starts so the manage UI can call `reload/0` after
  saving a credential without needing supervisor surgery.

  ## Options

  - `:token` — explicit token, bypasses Credential lookup (used in tests)
  - `:http` — `Req`-compatible request function used for both polling and
    sending (defaults to `&Req.request/1`); tests inject a stub
  - `:poll_interval_ms` — sleep before next `getUpdates` after an empty
    or failed call (default 1_000)
  - `:long_poll_timeout` — `timeout=` parameter passed to `getUpdates`
    (default 25 seconds)
  - `:name` — process name (default `__MODULE__`)
  """

  use GenServer
  require Logger

  alias Long.Agent.Bots
  alias Long.Agent.Bots.Telegram.{Credential, Format, Media}

  @default_long_poll_timeout 25
  @default_poll_interval_ms 1_000
  # Telegram's sendChatAction "typing" indicator lasts ~5 seconds, so
  # we re-send every 4 to keep the bubble alive throughout a turn.
  @typing_interval_ms 4_000
  # Hard cap on the keepalive — backstop for the case where the agent
  # task crashes hard enough that `on_complete` never fires and the
  # session PubSub stays silent (so `:loop_ended` doesn't arrive
  # either). 30 minutes is well past any realistic single-turn run.
  @typing_max_lifetime_ms 30 * 60_000

  # ── Public API ───────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Re-read the active `TelegramCredential` (or env var) and switch the
  running worker over. Called by the manage UI after a credential save
  / delete; safe to call when no worker exists yet.
  """
  def reload(server \\ __MODULE__) do
    target = if is_pid(server), do: server, else: Process.whereis(server)
    if target, do: send(target, :reload)
    :ok
  end

  def send_message(server \\ __MODULE__, chat_id, text) do
    GenServer.call(server, {:send_message, chat_id, text})
  end

  @doc """
  Push a collected `result` map (final assistant text + optional ask) to
  a Telegram chat. Used by `Long.Agent.Bots.Outbound` for proactive
  pushes from the scheduler. Attachments in `result.attachments` are
  uploaded via the same `sendPhoto` / `sendVideo` / `sendDocument`
  endpoints the inbound dispatch path uses.
  """
  @spec push(String.t() | integer(), map(), keyword()) :: :ok | {:error, term()}
  def push(chat_id, %{} = result, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    text = Map.get(result, :text, "") || ""
    ask = Map.get(result, :ask)
    attachments = Map.get(result, :attachments, []) || []
    body = render_reply(text, ask)

    cond do
      body == "" and attachments == [] -> :ok
      not worker_alive?(server) -> {:error, :telegram_worker_not_running}
      true -> deliver_push(server, chat_id, body, attachments)
    end
  end

  # `server` may be a pid (a per-bot worker resolved by `Outbound`), a
  # registered name (tests / legacy), or nil (no bot available).
  defp worker_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp worker_alive?(nil), do: false
  defp worker_alive?(name), do: not is_nil(Process.whereis(name))

  defp deliver_push(server, chat_id, body, attachments) do
    with {:ok, _} <- maybe_send_text(server, chat_id, body) do
      if attachments != [],
        do: GenServer.cast(server, {:send_attachments, chat_id, attachments})

      :ok
    end
  end

  defp maybe_send_text(_server, _chat_id, ""), do: {:ok, :skipped}
  defp maybe_send_text(server, chat_id, body), do: send_message(server, chat_id, body)

  @doc """
  Walk one Telegram update payload and return a structured message, or
  `nil` for shapes the agent can't react to (sticker / contact /
  location). A message qualifies for dispatch when it carries non-empty
  text/caption OR at least one media attachment we know how to fetch.
  """
  def extract_message(%{"message" => %{"chat" => chat, "from" => from} = msg}) do
    text = msg["text"] || msg["caption"] || ""
    media = Media.inbound_descriptors(msg)

    if text != "" or media != [] do
      %{
        chat_id: to_string(chat["id"]),
        user_id: to_string(from["id"]),
        text: text,
        media: media,
        locale: from["language_code"],
        display_name:
          [from["first_name"], from["last_name"]] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
      }
    end
  end

  def extract_message(_), do: nil

  # ── GenServer ────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    cred_name = Keyword.get(opts, :credential_name)
    {token, row} = resolve(cred_name, opts)

    state = %{
      credential_name: cred_name,
      member_id: row && row.member_id,
      token: token,
      http: Keyword.get(opts, :http, &Req.request/1),
      offset: 0,
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
      long_poll_timeout: Keyword.get(opts, :long_poll_timeout, @default_long_poll_timeout),
      # Resolved once at boot; avoids `Application.get_env` + `File.cwd!`
      # on the per-message hot path.
      media_dir: resolve_media_dir(),
      run_opts: Keyword.get(opts, :run_opts, [])
    }

    if is_nil(token) do
      Logger.info("Long.Agent.Bots.Telegram[#{cred_name || "-"}]: no credential; idle")
    else
      Logger.info("Long.Agent.Bots.Telegram[#{cred_name || "-"}]: credential loaded; long-polling")
      send(self(), :poll)
    end

    {:ok, state}
  end

  # `{token, row}` for this worker. An explicit `:token` (tests) wins and
  # carries no row; otherwise load this worker's own credential by name,
  # falling back to the first-enabled pick / env var when unnamed.
  defp resolve(cred_name, opts) do
    case Keyword.get(opts, :token) do
      t when is_binary(t) and t != "" ->
        {t, nil}

      _ ->
        loaded = if cred_name, do: Credential.load_named(cred_name), else: Credential.load()

        case loaded do
          {tok, row} -> {tok, row}
          _ -> {nil, nil}
        end
    end
  end

  @impl true
  def handle_info(:poll, %{token: nil} = state), do: {:noreply, state}

  def handle_info(:poll, state) do
    new_offset = poll_once(state)
    Process.send_after(self(), :poll, state.poll_interval_ms)
    {:noreply, %{state | offset: new_offset}}
  end

  def handle_info(:reload, state) do
    {new_token, row} = resolve(state.credential_name, [])
    member_id = row && row.member_id

    cond do
      new_token == state.token ->
        # Token unchanged, but the member assignment may have just changed.
        {:noreply, %{state | member_id: member_id}}

      is_nil(new_token) ->
        Logger.info("Telegram[#{state.credential_name || "-"}]: credential cleared; pausing")
        {:noreply, %{state | token: nil, member_id: member_id}}

      true ->
        Logger.info("Telegram[#{state.credential_name || "-"}]: credential changed; resuming")
        # Reset offset because the new bot has its own update id space.
        if is_nil(state.token), do: send(self(), :poll)
        {:noreply, %{state | token: new_token, member_id: member_id, offset: 0}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call({:send_message, _chat_id, _text}, _from, %{token: nil} = state) do
    {:reply, {:error, :no_credential}, state}
  end

  def handle_call({:send_message, chat_id, text}, _from, state) do
    result = call_send_message(state, chat_id, text)
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:send_attachments, _chat_id, _atts}, %{token: nil} = state),
    do: {:noreply, state}

  # Off-the-GenServer so a multi-file album upload doesn't block every
  # other inbound poll / send_message caller. Failures are best-effort
  # logged inside Media.send_attachment.
  def handle_cast({:send_attachments, chat_id, attachments}, state) do
    Task.Supervisor.start_child(Long.Agent.TaskSup, fn ->
      Enum.each(attachments, &Media.send_attachment(state, chat_id, &1))
    end)

    {:noreply, state}
  end

  # ── Polling ──────────────────────────────────────────────────────────────

  defp poll_once(state) do
    case fetch_updates(state) do
      {:ok, updates} when is_list(updates) ->
        Enum.each(updates, &spawn_handler(state, &1))
        next_offset_from(updates) || state.offset

      {:ok, _other} ->
        state.offset

      {:error, reason} ->
        Logger.warning("Telegram getUpdates failed: #{inspect(reason)}")
        state.offset
    end
  end

  defp fetch_updates(state) do
    state.http.(
      method: :get,
      url: "https://api.telegram.org/bot#{state.token}/getUpdates",
      params: %{offset: state.offset, timeout: state.long_poll_timeout},
      receive_timeout: (state.long_poll_timeout + 5) * 1_000,
      retry: false
    )
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"ok" => true, "result" => result}}} ->
        {:ok, result}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:error, {:bad_payload, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, e} ->
        {:error, e}
    end
  end

  defp next_offset_from([]), do: nil

  defp next_offset_from(updates) do
    updates |> Enum.map(& &1["update_id"]) |> Enum.max() |> Kernel.+(1)
  end

  # ── Dispatch ─────────────────────────────────────────────────────────────

  defp spawn_handler(state, update) do
    case extract_message(update) do
      nil ->
        :ok

      msg ->
        Task.start(fn -> handle_message(state, msg) end)
    end
  end

  defp handle_message(state, msg) do
    typing = start_typing(state, msg.chat_id)

    inbound_paths = download_inbound(state, msg.media)
    {image_paths, file_paths} = Enum.split_with(inbound_paths, &image?/1)
    body = compose_body(msg.text, file_paths)

    run_opts =
      Keyword.merge(state.run_opts,
        chat_id: msg.chat_id,
        display_name: msg.display_name,
        member_id: state.member_id,
        credential_name: state.credential_name,
        attachments: image_paths,
        metadata: %{"telegram" => true, "locale" => msg.locale},
        on_complete: fn _bot_user, result ->
          stop_typing(typing)

          case result do
            {:ok, %{text: text, ask: ask, attachments: attachments}} ->
              body = render_reply(text, ask)
              if body != "", do: call_send_message(state, msg.chat_id, body)
              send_outbound(state, msg.chat_id, attachments || [])

            {:error, e} ->
              call_send_message(state, msg.chat_id, render_error(e))
          end
        end
      )

    result = Bots.run_async(:telegram, msg.user_id, body, run_opts)

    # Hand the typing keepalive a session id so it can subscribe to the
    # PubSub topic and exit on `:loop_ended` instead of waiting for the
    # 30-min lifetime cap. For magic-command modes `on_complete` already
    # fired synchronously, so `stop_typing` was called there.
    case result do
      {:ok, %{session_id: sid, mode: :dispatched}} ->
        if is_pid(typing), do: send(typing, {:bind_session, sid})

      {:ok, _} ->
        :ok

      # `ensure_session` or the dispatch spawn failed: on_complete will
      # never fire, kill the typing process ourselves to avoid leaking
      # it until the lifetime cap.
      _ ->
        stop_typing(typing)
    end
  end

  # Inbound non-image attachments (PDF / doc / voice / …) stay on disk
  # under the workspace; the agent reaches them through `file_read` /
  # `code_run`. We append a one-line marker per file to the dispatched
  # text so the model knows the path. Images go through the multimodal
  # `:attachments` path instead and aren't mentioned here.
  defp compose_body("", []), do: ""

  defp compose_body("", paths),
    do: Enum.map_join(paths, "\n", &Long.Copy.t("chat.file_marker", %{path: &1}))

  defp compose_body(text, []), do: text

  defp compose_body(text, paths),
    do: text <> "\n" <> Enum.map_join(paths, "\n", &Long.Copy.t("chat.file_marker", %{path: &1}))

  @image_exts ~w(.jpg .jpeg .png .gif .webp .bmp)

  defp image?(path) when is_binary(path) do
    path |> Path.extname() |> String.downcase() |> then(&(&1 in @image_exts))
  end

  defp resolve_media_dir do
    base =
      Application.get_env(:long, Long.Agent, [])[:workspace_root] ||
        Path.expand("priv/agent/workspace", File.cwd!())

    Path.join([base, "telegram_inbox"])
  end

  # Skip the mkdir + Task overhead entirely for text-only messages.
  defp download_inbound(_state, []), do: []

  defp download_inbound(state, descriptors) do
    Media.download_all(descriptors, state.media_dir, state.token, state.http)
  end

  # Multi-file albums often arrive; fan out the uploads so a 5-image
  # send doesn't serialize HTTP round-trips. Errors are logged per
  # attempt inside Media.send_attachment.
  defp send_outbound(_state, _chat_id, []), do: :ok

  defp send_outbound(state, chat_id, [single]),
    do: Media.send_attachment(state, chat_id, single)

  defp send_outbound(state, chat_id, attachments) do
    attachments
    |> Task.async_stream(&Media.send_attachment(state, chat_id, &1),
      max_concurrency: 4,
      timeout: 60_000,
      on_timeout: :kill_task
    )
    |> Stream.run()
  end

  # Tool-call summary is intentionally dropped here — the model's own
  # text already narrates what it did and the duplicate `🛠 web_search`
  # list under a `---` divider was the main source of "杂" feedback.
  # If you ever want it back, fold it into Format.to_html with a
  # discreet `<i>` footer.
  defp render_reply(text, nil), do: Format.to_html(text)

  defp render_reply(text, %{"question" => q}) do
    [Format.to_html(text), "❓ " <> Format.to_html(q)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp render_reply(text, _other), do: render_reply(text, nil)

  defp render_error(e) do
    Long.Copy.t("chat.error", %{reason: Format.to_html(Long.Util.Error.humanize(e))})
  end

  # Send `text` as one or more HTML-mode messages. Returns the last
  # API response (or the first error) so callers stay backward
  # compatible with the {:ok, _} | {:error, _} contract.
  defp call_send_message(state, chat_id, text) do
    text
    |> Format.chunks()
    |> Enum.reduce_while({:ok, :empty}, fn chunk, _ ->
      case send_chunk(state, chat_id, chunk) do
        {:ok, _} = ok -> {:cont, ok}
        err -> {:halt, err}
      end
    end)
  end

  defp send_chunk(state, chat_id, chunk) do
    state.http.(
      method: :post,
      url: "https://api.telegram.org/bot#{state.token}/sendMessage",
      json: %{
        chat_id: chat_id,
        text: chunk,
        parse_mode: "HTML",
        # Long agent replies often include links; the previews can be
        # noisy in a chat thread, especially when the assistant
        # paraphrases the page below.
        disable_web_page_preview: true
      }
    )
  end

  # ── Typing keepalive ─────────────────────────────────────────────────
  #
  # Telegram's `sendChatAction` makes the "typing…" bubble appear in
  # the chat. The indicator auto-clears after ~5s, so a long agent
  # turn needs a periodic refresh — otherwise the user thinks the bot
  # ate their message. We run the loop in a detached Task (no link)
  # so it survives this dispatcher's exit; `on_complete` is what
  # eventually signals it to stop. If we never hear back (agent crash
  # hard enough that no PubSub event ever fires), the lifetime cap
  # closes the leak.

  defp start_typing(state, chat_id) do
    case Task.Supervisor.start_child(Long.Agent.TaskSup, fn ->
           typing_loop(state, chat_id, System.monotonic_time(:millisecond))
         end) do
      {:ok, pid} -> pid
      _ -> nil
    end
  end

  defp stop_typing(nil), do: :ok

  defp stop_typing(pid) when is_pid(pid) do
    # `send/2` to a dead local pid is a no-op; no need to probe alive?.
    send(pid, :stop)
    :ok
  end

  defp typing_loop(state, chat_id, started_at) do
    # First ping fires immediately so the bubble shows up the moment
    # the user sends their message, not 4 seconds later.
    _ = send_chat_action(state, chat_id, "typing")
    typing_loop_step(state, chat_id, started_at)
  end

  defp typing_loop_step(state, chat_id, started_at) do
    receive do
      :stop -> :ok
      # Session PubSub signals — either flavour means the turn finished
      # (cleanly or via crash-and-rescue). The reply send will replace
      # the bubble naturally.
      :loop_ended -> :ok
      {:loop_error, _} -> :ok
      {:bind_session, session_id} ->
        Long.SessionRunner.subscribe(session_id)
        typing_loop_step(state, chat_id, started_at)

      # The session topic broadcasts intermediate events we don't
      # care about (`:loop_started`, `{:turn_start, _}`, `{:tool_start,
      # _}`, `{:message_persisted, _}`, `{:done, _}`, …). Drain them so
      # the receive can match the next real exit signal — otherwise an
      # early `:loop_started` would sit at the head of the mailbox and
      # block `:loop_ended`.
      _ ->
        typing_loop_step(state, chat_id, started_at)
    after
      @typing_interval_ms ->
        if System.monotonic_time(:millisecond) - started_at > @typing_max_lifetime_ms do
          :ok
        else
          _ = send_chat_action(state, chat_id, "typing")
          typing_loop_step(state, chat_id, started_at)
        end
    end
  end

  defp send_chat_action(state, chat_id, action) do
    state.http.(
      method: :post,
      url: "https://api.telegram.org/bot#{state.token}/sendChatAction",
      json: %{chat_id: chat_id, action: action}
    )
  end
end
