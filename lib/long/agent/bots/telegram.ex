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
  alias Long.Agent.Bots.Telegram.Credential

  @default_long_poll_timeout 25
  @default_poll_interval_ms 1_000

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
    if pid = Process.whereis(server), do: send(pid, :reload)
    :ok
  end

  def send_message(server \\ __MODULE__, chat_id, text) do
    GenServer.call(server, {:send_message, chat_id, text})
  end

  @doc """
  Push a collected `result` map (final assistant text + optional ask) to
  a Telegram chat. Used by `Long.Agent.Bots.Outbound` for proactive
  pushes from the scheduler. No attachment support — Telegram media
  uploads aren't wired yet, so attachments are dropped (a future
  enhancement can route them through `sendPhoto` / `sendDocument`).
  """
  @spec push(String.t() | integer(), map(), keyword()) :: :ok | {:error, term()}
  def push(chat_id, %{} = result, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    text = Map.get(result, :text, "") || ""
    ask = Map.get(result, :ask)
    body = render_reply(text, [], ask)

    cond do
      body == "" ->
        :ok

      is_nil(Process.whereis(server)) ->
        {:error, :telegram_worker_not_running}

      true ->
        case send_message(server, chat_id, body) do
          {:ok, _} -> :ok
          err -> {:error, err}
        end
    end
  end

  @doc """
  Pure function: walk one Telegram update payload and return the structured
  message it contains, or `nil`. Exposed for tests.
  """
  def extract_message(%{"message" => %{"chat" => chat, "from" => from} = msg}) do
    text = msg["text"] || msg["caption"]

    if is_binary(text) and text != "" do
      %{
        chat_id: to_string(chat["id"]),
        user_id: to_string(from["id"]),
        text: text,
        display_name:
          [from["first_name"], from["last_name"]] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
      }
    end
  end

  def extract_message(_), do: nil

  # ── GenServer ────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    {token, row} =
      case Keyword.get(opts, :token) do
        t when is_binary(t) and t != "" -> {t, nil}
        _ -> Credential.load() || {nil, nil}
      end

    state = %{
      token: token,
      row: row,
      http: Keyword.get(opts, :http, &Req.request/1),
      offset: 0,
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
      long_poll_timeout: Keyword.get(opts, :long_poll_timeout, @default_long_poll_timeout),
      run_opts: Keyword.get(opts, :run_opts, [])
    }

    if is_nil(token) do
      Logger.info("Long.Agent.Bots.Telegram: no credential; idle until configured")
    else
      Logger.info("Long.Agent.Bots.Telegram: credential loaded; starting long-poll")
      send(self(), :poll)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:poll, %{token: nil} = state), do: {:noreply, state}

  def handle_info(:poll, state) do
    new_offset = poll_once(state)
    Process.send_after(self(), :poll, state.poll_interval_ms)
    {:noreply, %{state | offset: new_offset}}
  end

  def handle_info(:reload, state) do
    case Credential.load() do
      nil ->
        if state.token,
          do: Logger.info("Long.Agent.Bots.Telegram: credential cleared; pausing")

        {:noreply, %{state | token: nil, row: nil}}

      {token, row} ->
        if state.token == token do
          # No token change — refresh the row reference so future
          # username writes target the current record.
          {:noreply, %{state | row: row}}
        else
          Logger.info("Long.Agent.Bots.Telegram: credential changed; resuming long-poll")
          # Reset offset because the new bot has its own update id space.
          if is_nil(state.token), do: send(self(), :poll)
          {:noreply, %{state | token: token, row: row, offset: 0}}
        end
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
    run_opts =
      Keyword.merge(state.run_opts,
        chat_id: msg.chat_id,
        display_name: msg.display_name,
        metadata: %{"telegram" => true},
        on_complete: fn _bot_user, result ->
          case result do
            {:ok, %{text: text, tool_calls: tool_calls, ask: ask}} ->
              body = render_reply(text, tool_calls, ask)
              if body != "", do: call_send_message(state, msg.chat_id, body)

            {:error, e} ->
              call_send_message(state, msg.chat_id, "[error] #{inspect(e)}")
          end
        end
      )

    Bots.run_async(:telegram, msg.user_id, msg.text, run_opts)
  end

  defp render_reply(text, tool_calls, nil) do
    summary = Bots.summarize_tool_calls(tool_calls)
    [text, summary] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n\n---\n")
  end

  defp render_reply(text, tool_calls, %{"question" => q}) do
    base = render_reply(text, tool_calls, nil)
    [base, "❓ " <> q] |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")
  end

  defp render_reply(text, tool_calls, _other), do: render_reply(text, tool_calls, nil)

  defp call_send_message(state, chat_id, text) do
    state.http.(
      method: :post,
      url: "https://api.telegram.org/bot#{state.token}/sendMessage",
      json: %{chat_id: chat_id, text: text}
    )
  end
end
