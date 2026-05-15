defmodule Long.Agent.Bots.Wechat.Client do
  @moduledoc """
  HTTP client for iLink AI Bot endpoints (`ilinkai.weixin.qq.com`).

  This is the Elixir port of `frontends/wechatapp.py::WxBotClient`. The
  endpoints are Tencent's officially-sanctioned channel for AI bots
  bound to a personal WeChat account — registration happens via QR
  scan, no third-party hooks involved.

  Most calls are pure HTTP + JSON; the only stateful piece is the
  `updates_buf` cursor returned by `get_updates/2`, which the caller is
  expected to thread back into subsequent calls (or persist via
  `Long.Agent.Bots.Wechat.TokenStore`).
  """

  import Bitwise

  alias Long.Agent.Bots.Wechat.Credential

  @api_base "https://ilinkai.weixin.qq.com"
  @ua "openclaw-weixin/2.1.10"
  @channel_version "2.1.10"
  @ilink_app_id "bot"
  @ilink_app_client_version bor(bor(2 <<< 16, 1 <<< 8), 10)

  @type msg_type :: pos_integer()
  @type item_type :: pos_integer()

  # ── Message-type constants (mirror Python's MSG_USER / MSG_BOT etc.) ─

  @msg_user 1
  @msg_bot 2
  @state_finish 2

  @item_text 1
  @item_image 2
  @item_file 4
  @item_video 5

  def msg_user, do: @msg_user
  def msg_bot, do: @msg_bot
  def item_text, do: @item_text
  def item_image, do: @item_image
  def item_file, do: @item_file
  def item_video, do: @item_video
  def state_finish, do: @state_finish

  # ── QR login ──────────────────────────────────────────────────────────

  @doc """
  Request a fresh bot-login QR code. Returns
  `{:ok, %{qr_id, qr_url}}` — render `qr_url` as a QR image and have
  the operator scan it from WeChat.
  """
  def get_qrcode do
    case Req.get(@api_base <> "/ilink/bot/get_bot_qrcode",
           params: [bot_type: 3],
           headers: [{"user-agent", @ua}],
           receive_timeout: 10_000
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case decode_json(body) do
          {:ok, %{"qrcode" => qr_id} = json} ->
            {:ok, %{qr_id: qr_id, qr_url: Map.get(json, "qrcode_img_content", "")}}

          _ ->
            {:error, {:bad_qrcode_response, body}}
        end

      {:ok, %Req.Response{body: body}} ->
        {:error, {:bad_qrcode_response, body}}

      {:error, e} ->
        {:error, e}
    end
  end

  @doc """
  Poll the QR status. Server returns `"new"` → `"scanned"` → `"confirmed"`,
  or `"expired"` after timeout. On `"confirmed"` the response contains
  `bot_token` and `ilink_bot_id`.
  """
  def get_qrcode_status(qr_id) do
    case Req.get(@api_base <> "/ilink/bot/get_qrcode_status",
           params: [qrcode: qr_id],
           headers: [{"user-agent", @ua}],
           receive_timeout: 60_000
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case decode_json(body) do
          {:ok, json} -> {:ok, json}
          _ -> {:error, {:bad_status_response, body}}
        end

      {:ok, %Req.Response{body: body}} ->
        {:error, {:bad_status_response, body}}

      {:error, %{__exception__: true} = e} ->
        {:error, Exception.message(e)}

      {:error, e} ->
        {:error, e}
    end
  end

  # ── Long-poll messages ────────────────────────────────────────────────

  @doc """
  Long-poll for new messages. Pass the previous `updates_buf` cursor in
  `state.updates_buf`. Returns `{:ok, %{msgs, updates_buf}}`. A
  `errcode == -14` response signals the cursor went stale; the caller
  should reset it to `""` and retry.
  """
  def get_updates(%{} = state, timeout_seconds \\ 30) do
    body = %{
      "get_updates_buf" => state[:updates_buf] || "",
      "base_info" => %{"channel_version" => @channel_version}
    }

    # iLink long-polls; give Req a few extra seconds to receive the
    # final 200 after the server's own timeout fires.
    case post("ilink/bot/getupdates", state, body, timeout_seconds + 5) do
      {:ok, %{"errcode" => -14}} ->
        {:ok, %{msgs: [], updates_buf: "", stale_cursor: true}}

      {:ok, %{"errcode" => code} = body} when is_integer(code) and code != 0 ->
        {:error, {:ilink_error, code, Map.get(body, "errmsg", "")}}

      {:ok, body} ->
        {:ok,
         %{
           msgs: body["msgs"] || [],
           updates_buf: body["get_updates_buf"] || state[:updates_buf] || ""
         }}

      err ->
        err
    end
  end

  # ── Send text / typing ────────────────────────────────────────────────

  @doc """
  Send a plain-text message. `to_user_id` is the user's iLink id (from
  the inbound `from_user_id` field).
  """
  def send_text(state, to_user_id, text, opts \\ []) do
    msg = %{
      "from_user_id" => "",
      "to_user_id" => to_user_id,
      "client_id" => client_id(),
      "message_type" => @msg_bot,
      "message_state" => @state_finish,
      "item_list" => [%{"type" => @item_text, "text_item" => %{"text" => text}}]
    }

    msg = maybe_put_context(msg, opts[:context_token])

    post(
      "ilink/bot/sendmessage",
      state,
      %{"msg" => msg, "base_info" => %{"channel_version" => @channel_version}}
    )
  end

  @doc """
  Send a typing indicator. Pass `cancel: true` to stop. `typing_ticket`
  is obtained via `get_typing_ticket/3`.
  """
  def send_typing(state, to_user_id, typing_ticket, opts \\ []) do
    body = %{
      "ilink_user_id" => to_user_id,
      "typing_ticket" => typing_ticket || "",
      "status" => if(opts[:cancel], do: 2, else: 1),
      "base_info" => %{"channel_version" => @channel_version}
    }

    post("ilink/bot/sendtyping", state, body)
  end

  @doc "Fetch a typing ticket (required before `send_typing`)."
  def get_typing_ticket(state, to_user_id, context_token \\ "") do
    body =
      %{"ilink_user_id" => to_user_id}
      |> maybe_put_context(context_token)

    case post("ilink/bot/getconfig", state, body) do
      {:ok, resp} -> {:ok, Map.get(resp, "typing_ticket", "")}
      err -> err
    end
  end

  # ── Helpers exposed for the Media module ──────────────────────────────

  @doc "Generic POST to an iLink endpoint with the bot token attached."
  def post(endpoint, state, body, timeout_seconds \\ 15) do
    data = Jason.encode!(body)

    headers =
      [
        {"content-type", "application/json"},
        {"authorizationtype", "ilink_bot_token"},
        {"content-length", to_string(byte_size(data))},
        {"x-wechat-uin", uin()},
        {"ilink-app-id", @ilink_app_id},
        {"ilink-app-clientversion", to_string(@ilink_app_client_version)},
        {"user-agent", @ua}
      ]
      |> maybe_authorization(state[:bot_token])

    case Req.post(@api_base <> "/" <> endpoint,
           headers: headers,
           body: data,
           receive_timeout: timeout_seconds * 1000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case decode_json(body) do
          {:ok, json} -> {:ok, json}
          _ -> {:error, {:bad_status, 200, body}}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:bad_status, status, body}}

      {:error, %{__exception__: true} = e} ->
        {:error, Exception.message(e)}

      {:error, e} ->
        {:error, e}
    end
  end

  # iLink returns JSON but sometimes with `Content-Type: text/plain;
  # charset=utf-8` — Req's auto-decoder keeps the body as a binary in
  # that case, so we always re-decode here.
  defp decode_json(body) when is_map(body), do: {:ok, body}

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, m} when is_map(m) -> {:ok, m}
      _ -> :error
    end
  end

  defp decode_json(_), do: :error

  def channel_version, do: @channel_version
  def ua, do: @ua
  def cdn_base, do: "https://novac2c.cdn.weixin.qq.com/c2c"

  # ── Message-shape helpers ─────────────────────────────────────────────

  @doc "Concatenate text from all `text_item` parts in an inbound message."
  def extract_text(%{"item_list" => items}) when is_list(items) do
    items
    |> Enum.filter(&(&1["type"] == @item_text and is_map(&1["text_item"])))
    |> Enum.map_join("\n", &(get_in(&1, ["text_item", "text"]) || ""))
  end

  def extract_text(_), do: ""

  @doc "True when the message comes from a user (vs. our own bot echo)."
  def user_msg?(%{"message_type" => @msg_user}), do: true
  def user_msg?(_), do: false

  @doc "Load the stored credential into a state map suitable for the call helpers."
  def state_from_token do
    case Credential.load() do
      nil -> %{bot_token: "", ilink_bot_id: "", updates_buf: ""}
      tok -> tok
    end
  end

  # ── Internal ──────────────────────────────────────────────────────────

  defp client_id, do: "elixir-" <> (Ecto.UUID.generate() |> String.replace("-", "") |> binary_part(0, 16))

  defp uin do
    <<n::32>> = :crypto.strong_rand_bytes(4)
    n |> Integer.to_string() |> Base.encode64()
  end

  defp maybe_put_context(msg, nil), do: msg
  defp maybe_put_context(msg, ""), do: msg
  defp maybe_put_context(msg, ctx) when is_binary(ctx), do: Map.put(msg, "context_token", ctx)

  defp maybe_authorization(headers, nil), do: headers
  defp maybe_authorization(headers, ""), do: headers
  defp maybe_authorization(headers, tok) when is_binary(tok),
    do: [{"authorization", "Bearer " <> String.trim(tok)} | headers]
end
