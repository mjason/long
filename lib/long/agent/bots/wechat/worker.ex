defmodule Long.Agent.Bots.Wechat.Worker do
  @moduledoc """
  Long-poll loop that bridges iLink bot messages into the agent
  session runtime.

  Lifecycle:

    1. On `init/1`, load the token via `TokenStore`. If absent, log a
       hint and stay idle — the user is expected to run
       `mix long.wechat.login` to populate it, then restart.
    2. Once tokened, repeatedly call `Client.get_updates/2`. For every
       user-authored message, dispatch a per-message Task that:
         - downloads any media into `priv/agent/wechat_temp/`
         - kicks off typing keepalive
         - calls `Long.Agent.Bots.run_and_collect(:wechat, ...)`
         - sends the cleaned response back as text + media
    3. Persist the `updates_buf` cursor to disk after every poll so
       restarts don't replay old messages.
  """

  use GenServer
  require Logger

  alias Long.Agent.Bots
  alias Long.Agent.Bots.Wechat
  alias Long.Agent.Bots.Wechat.{Client, Credential, Media}

  @poll_timeout_seconds 30
  @retry_delay_ms 5_000
  @max_seen_msgs 5_000

  # WeChat delivers a "caption + file/image" as separate messages a beat apart
  # (observed 0.3–2.3s). Buffer a user's inbound messages for this window, then
  # dispatch them as ONE multimodal turn — so the model sees text + attachments
  # together and we don't split them across two turns (which dropped the
  # attachment and fired a spurious "still processing" ack). Cost: a lone
  # message waits up to this long before the agent starts. Tune via config.
  @coalesce_ms 2_000
  # iLink "正在输入" bubble lifetime is not documented; empirically a
  # ping every 4s keeps it visible without hammering the API. 2s was
  # over-pinging; >5s lets the bubble flicker off briefly between pings.
  @typing_interval_ms 4_000
  # Hard cap on how long we keep the typing process alive. The primary
  # exit signals are `:stop` (from `on_complete`) and `:loop_ended`
  # (from the session's PubSub topic once we bind to it), so legitimate
  # long runs of any duration are covered. The cap is purely a backstop
  # for brutal-killed agent tasks where neither signal ever fires —
  # bumped from 10m to 30m because real ReAct loops with many
  # web_scan / code_run rounds routinely exceed 10 minutes.
  @typing_max_lifetime_ms 30 * 60_000

  @registry Long.Agent.Bots.Wechat.Registry

  @doc """
  Start a worker for one hosted WeChat account. `opts` must carry
  `:name` — the `WechatCredential` name this worker polls. Registered
  under `name` in `#{inspect(@registry)}` so `Long.Agent.Bots.Wechat.Manager`
  can run several accounts side by side.
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  defp via(name), do: {:via, Registry, {@registry, name}}

  @doc """
  Re-read the named account's stored credential and resume (or pause)
  polling — used after a re-login of that same account refreshes its
  token. Adding/removing accounts is `Manager`'s job, not this.
  """
  def reload(name), do: send_safe(name, :reload)

  defp send_safe(name, msg) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] -> send(pid, msg)
      [] -> :no_worker
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    name = Keyword.fetch!(opts, :name)

    case active_credential(name) do
      nil ->
        Logger.info("Wechat.Worker[#{name}]: no usable token yet; idle until one is saved.")
        {:ok, %{name: name, token: nil, seen: MapSet.new(), buffers: %{}}}

      cred ->
        Logger.info("Wechat.Worker[#{name}]: credential loaded (bot_id=#{cred.ilink_bot_id})")
        send(self(), :poll)
        {:ok, %{name: name, token: cred, seen: MapSet.new(), buffers: %{}}}
    end
  end

  # A credential is only pollable once it has a non-empty bot_token — a
  # row can exist with just a name + assigned member (pre-scan), in which
  # case the worker stays idle instead of long-polling with an empty token.
  defp active_credential(name) do
    case Credential.load(name) do
      %{bot_token: t} = cred when is_binary(t) and t != "" -> cred
      _ -> nil
    end
  end

  @impl true
  def handle_info(:poll, %{token: nil} = state), do: {:noreply, state}

  def handle_info(:poll, %{token: tok} = state) do
    # Long-poll OFF the GenServer. `get_updates` blocks ~35s synchronously; if it
    # ran here it would freeze the whole GenServer mailbox — including the 2s
    # coalesce `{:flush, uid}` timer message — so a lone inbound message would
    # only be processed when the next poll returns (up to ~35s later). Running
    # the poll in a Task keeps the worker responsive: flushes fire on time.
    worker = self()

    spawn =
      Task.Supervisor.start_child(Long.Agent.TaskSup, fn ->
        # Always send a result back, even on a raise/exit — otherwise the worker
        # never receives {:updates} and the poll loop stalls silently.
        result =
          try do
            Client.get_updates(tok, @poll_timeout_seconds)
          rescue
            e -> {:error, e}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        send(worker, {:updates, result})
      end)

    # The next :poll is re-armed by handle_info({:updates, _}). If the Task
    # never spawns (TaskSup momentarily down), no {:updates} ever arrives and
    # the poll loop would wedge alive-but-silent — re-arm here so it self-heals,
    # the way Telegram's loop already does unconditionally.
    case spawn do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Wechat[#{state.name}]: poll task spawn failed: #{inspect(reason)}; " <>
            "retrying in #{@retry_delay_ms}ms"
        )

        Process.send_after(self(), :poll, @retry_delay_ms)
    end

    {:noreply, state}
  end

  # A poll Task's result arrived after the credential was unloaded — drop it.
  def handle_info({:updates, _result}, %{token: nil} = state), do: {:noreply, state}

  def handle_info({:updates, result}, state) do
    # Beat on every completed poll cycle (success OR error) — a liveness signal
    # that the loop is still cycling, mirroring Telegram. A wedged loop stops
    # beating; a transient getUpdates error does not falsely mark it stale.
    Long.Heartbeat.beat({:wechat, state.name})

    case result do
      {:ok, %{msgs: msgs, updates_buf: buf} = r} ->
        token =
          if buf != state.token.updates_buf do
            Credential.save_buf(buf, state.name)
            %{state.token | updates_buf: buf}
          else
            state.token
          end

        if r[:stale_cursor], do: Logger.warning("Wechat[#{state.name}]: cursor went stale, reset")

        state = dispatch_messages(msgs, %{state | token: token})
        send(self(), :poll)
        {:noreply, state}

      {:error, e} ->
        Logger.error("Wechat: get_updates failed: #{inspect(e)}; retrying in #{@retry_delay_ms}ms")
        Process.send_after(self(), :poll, @retry_delay_ms)
        {:noreply, state}
    end
  end

  def handle_info(:reload, state) do
    case active_credential(state.name) do
      nil ->
        Logger.info("Wechat[#{state.name}]: reload found no usable credential — pausing")
        {:noreply, %{state | token: nil}}

      cred ->
        Logger.info("Wechat[#{state.name}]: reload picked up credential (bot_id=#{cred.ilink_bot_id})")
        # Only kick a fresh poll if we weren't already running.
        if is_nil(state.token), do: send(self(), :poll)
        {:noreply, %{state | token: cred}}
    end
  end

  # Flush a user's buffered burst as ONE combined turn (see @coalesce_ms).
  def handle_info({:flush, uid}, %{token: token} = state) when not is_nil(token) do
    {buffered, buffers} = Map.pop(state.buffers, uid, [])

    case Enum.reverse(buffered) do
      [] ->
        {:noreply, %{state | buffers: buffers}}

      msgs ->
        member_id = token[:member_id]
        credential_name = state.name

        Task.Supervisor.start_child(Long.Agent.TaskSup, fn ->
          handle_buffered(token, member_id, credential_name, uid, msgs)
        end)

        {:noreply, %{state | buffers: buffers}}
    end
  end

  # Credential was unloaded between buffering and flush — drop the burst.
  def handle_info({:flush, uid}, state) do
    {:noreply, %{state | buffers: Map.delete(state.buffers, uid)}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # ── Message dispatch ─────────────────────────────────────────────────

  defp dispatch_messages([], state), do: state

  defp dispatch_messages(msgs, state) do
    Enum.reduce(msgs, state, fn msg, acc ->
      mid = Map.get(msg, "message_id", 0)

      cond do
        not Client.user_msg?(msg) ->
          acc

        MapSet.member?(acc.seen, mid) ->
          acc

        true ->
          acc = %{acc | seen: prune(MapSet.put(acc.seen, mid))}
          buffer_message(acc, msg)
      end
    end)
  end

  # Append a message to its sender's buffer; on the first message of a burst,
  # arm the flush timer. Later messages within the window join the same buffer
  # (fixed window from the first message, not reset-on-each), so a burst's
  # latency is bounded to @coalesce_ms. The member_id/token are read at flush
  # time from the (then-current) credential, not cached per message.
  defp buffer_message(state, msg) do
    uid = Map.get(msg, "from_user_id", "")
    existing = Map.get(state.buffers, uid, [])
    if existing == [], do: Process.send_after(self(), {:flush, uid}, coalesce_ms())
    %{state | buffers: Map.put(state.buffers, uid, [msg | existing])}
  end

  defp coalesce_ms, do: Application.get_env(:long, Long.Agent, [])[:wechat_coalesce_ms] || @coalesce_ms

  defp prune(seen) when is_struct(seen, MapSet) do
    case MapSet.size(seen) do
      n when n > @max_seen_msgs ->
        seen |> MapSet.to_list() |> Enum.take(-div(@max_seen_msgs, 2)) |> MapSet.new()

      _ ->
        seen
    end
  end

  # ── One inbound message → agent → outbound text/media ────────────────

  defp handle_buffered(token, member_id, credential_name, uid, msgs) do
    # WeChat splits a "caption + file/image" across separate messages; combine
    # the buffered burst's text and media into ONE multimodal turn so the model
    # sees them together (and no half lands mid-reply triggering an enqueue ack).
    text = combined_text(msgs)
    ctx_token = msgs |> List.last() |> Map.get("context_token", "")

    # Stage inbound files into THIS session's own workspace inbox — the exact
    # dir code_run is sandboxed to — so bound AND unbound chats alike can open
    # them. Ensure the session up front to get the same id run_async reuses;
    # fall back to the shared inbox if it can't be ensured.
    base_opts = [session_title: "wechat:#{uid}", member_id: member_id, credential_name: credential_name]

    dir =
      case Bots.ensure_session(:wechat, uid, base_opts) do
        {:ok, %{session_id: sid}} -> Long.Agent.session_inbox(sid)
        _ -> media_dir()
      end

    media_paths = Enum.flat_map(msgs, &Media.download_all(&1, dir))

    {image_paths, file_paths} = Enum.split_with(media_paths, &image?/1)
    body = build_body(text, file_paths)

    if body == "" and image_paths == [] do
      :skip
    else
      Logger.info("Wechat <- #{String.slice(body, 0, 80)}#{attach_summary(image_paths)}")

      typing = start_typing(token, uid, ctx_token)

      # Fire the agent on a background task; reply when `:loop_ended`
      # arrives instead of blocking this Worker process. Without this,
      # a long-running agent run (>2 min) silently dropped the reply
      # because the synchronous `run_and_collect` timed out before the
      # final assistant message landed.
      result =
        Bots.run_async(
          :wechat,
          uid,
          body,
          Keyword.merge(base_opts,
            attachments: image_paths,
            on_complete: fn _bot_user, result ->
              stop_typing(typing)
              send_reply(token, uid, ctx_token, result, media_paths)
            end
          )
        )

      # Let the typing keepalive subscribe to the session's PubSub so
      # it can exit on `:loop_ended` regardless of how long the run
      # takes — the 30-min lifetime cap inside `typing_loop` only
      # exists as backstop for brutal-killed agent tasks where no
      # `:loop_ended` event ever fires.
      case result do
        {:ok, %{session_id: sid, mode: :dispatched}} ->
          if is_pid(typing), do: send(typing, {:bind_session, sid})

        # Magic-command modes (:cleared / :status / :btw) already fired
        # `on_complete` synchronously, so `stop_typing` was called for
        # them. Nothing to do.
        {:ok, _} ->
          :ok

        # `ensure_session` (or the dispatch spawn) failed: `on_complete`
        # will never fire, so kill the typing process ourselves to
        # avoid leaking it until the lifetime cap.
        _ ->
          stop_typing(typing)
      end
    end
  end

  # Non-image attachments stay as text references — the agent can read
  # them via `file_read` / `code_run` since the download dir is under
  # the workspace root. Images go through the multimodal path so the
  # LLM actually sees them.
  defp build_body("", []), do: ""
  defp build_body("", paths), do: Enum.map_join(paths, "\n", &Long.Copy.t("chat.file_marker", %{path: &1}))

  defp build_body(text, []), do: text

  defp build_body(text, paths) do
    text <> "\n" <> Enum.map_join(paths, "\n", &Long.Copy.t("chat.file_marker", %{path: &1}))
  end

  # Join the captions from a buffered burst (usually one text). Pure; public
  # only so the coalescing behavior is unit-testable.
  @doc false
  def combined_text(msgs) do
    msgs
    |> Enum.map(&(Client.extract_text(&1) |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp attach_summary([]), do: ""

  defp attach_summary(paths) do
    " (+#{length(paths)} image#{if length(paths) > 1, do: "s", else: ""})"
  end

  @image_exts ~w(.jpg .jpeg .png .gif .webp .bmp)

  defp image?(path) when is_binary(path) do
    Path.extname(path) |> String.downcase() |> then(&(&1 in @image_exts))
  end

  # ── Reply rendering ──────────────────────────────────────────────────

  defp send_reply(_token, _uid, _ctx, {:error, e}, _media) do
    Logger.warning("Wechat: agent error #{inspect(e)}")
  end

  defp send_reply(token, uid, ctx, {:ok, result}, _in_media) do
    Wechat.push_with_token(token, uid, result, context_token: ctx)
  end

  # ── Typing keepalive ─────────────────────────────────────────────────

  # Detached from the caller via `Task.Supervisor.start_child` (no link,
  # no monitor) so typing survives this Worker task exiting — the
  # reply-watcher in `Bots.run_async` is what calls `stop_typing/1`
  # later, often many minutes after `handle_message` already returned.
  defp start_typing(token, uid, ctx_token) do
    case Client.get_typing_ticket(token, uid, ctx_token) do
      {:ok, ticket} when ticket != "" ->
        case Task.Supervisor.start_child(Long.Agent.TaskSup, fn ->
               typing_loop(token, uid, ticket)
             end) do
          {:ok, pid} -> pid
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp stop_typing(nil), do: :ok

  defp stop_typing(pid) when is_pid(pid) do
    # `send/2` to a dead local pid is a no-op; the alive? probe was TOCTOU theatre.
    send(pid, :stop)
    :ok
  end

  defp typing_loop(token, uid, ticket) do
    # First ping fires immediately so the user sees the bubble appear
    # right after sending — not 4 seconds later.
    _ = Client.send_typing(token, uid, ticket)
    typing_loop_step(token, uid, ticket, System.monotonic_time(:millisecond))
  end

  defp typing_loop_step(token, uid, ticket, started_at) do
    receive do
      :stop ->
        cancel_typing(token, uid, ticket)
        :ok

      # Either signal from the session's PubSub means the agent run is
      # over (cleanly or via crash-and-rescue). Cancel and exit so the
      # bubble doesn't linger past the reply.
      :loop_ended ->
        cancel_typing(token, uid, ticket)
        :ok

      {:loop_error, _} ->
        cancel_typing(token, uid, ticket)
        :ok

      {:bind_session, session_id} ->
        Long.SessionRunner.subscribe(session_id)
        typing_loop_step(token, uid, ticket, started_at)

      # The session topic broadcasts a lot of intermediate events
      # we don't care about (`:loop_started`, `{:turn_start, _}`,
      # `{:tool_start, _}`, `{:message_persisted, _}`, `{:done, _}`,
      # …). Drain them so the receive can match the next real exit
      # signal — otherwise an early `:loop_started` would sit at the
      # head of the mailbox and block `:loop_ended`.
      _ ->
        typing_loop_step(token, uid, ticket, started_at)
    after
      @typing_interval_ms ->
        if System.monotonic_time(:millisecond) - started_at > @typing_max_lifetime_ms do
          :ok
        else
          _ = Client.send_typing(token, uid, ticket)
          typing_loop_step(token, uid, ticket, started_at)
        end
    end
  end

  # Explicitly tell iLink to cancel the bubble so it disappears the
  # moment the agent's reply lands, instead of waiting for the
  # indicator to fade on its own.
  defp cancel_typing(token, uid, ticket) do
    _ = Client.send_typing(token, uid, ticket, cancel: true)
    :ok
  end

  # ── Filesystem ───────────────────────────────────────────────────────

  # Downloaded media lands inside the workspace root so the agent's
  # `file_read` / `code_run` tools (which enforce a workspace-root
  # path guard) can read inbound files. The agent sees user-supplied
  # PDFs / text / etc. via these tools; images flow through the
  # multimodal `:attachments` path instead.
  defp media_dir do
    base =
      Application.get_env(:long, Long.Agent, [])[:workspace_root] ||
        Path.expand("priv/agent/workspace", File.cwd!())

    Path.join([base, "wechat_inbox"])
  end
end
