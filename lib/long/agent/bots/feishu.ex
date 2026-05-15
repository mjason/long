defmodule Long.Agent.Bots.Feishu do
  @moduledoc """
  Feishu (Lark) bot adapter. Inbound messages arrive via the
  `LongWeb.FeishuController` webhook; this module is responsible for:

  - URL verification handshake (`url_verification` event)
  - Decoding the incoming `im.message.receive_v1` event
  - Calling `Long.Agent.Bots.run_and_collect/4`
  - Posting the reply back via `POST /open-apis/im/v1/messages/:id/reply`

  Credentials are read from environment variables on each call so they can
  be rotated without a restart:

  - `FEISHU_APP_ID`, `FEISHU_APP_SECRET` — required to mint tenant tokens
  - `FEISHU_VERIFICATION_TOKEN` — shared secret echoed in events
  """

  alias Long.Agent.Bots

  @api_base "https://open.feishu.cn/open-apis"
  @token_path "/auth/v3/tenant_access_token/internal"

  @doc "Handle a verification challenge payload. Returns the JSON body to echo back."
  def handle_verification(%{"challenge" => challenge}), do: %{"challenge" => challenge}
  def handle_verification(_), do: %{"error" => "missing challenge"}

  @doc """
  Process an `im.message.receive_v1` event. Returns one of:

  - `{:ok, :accepted}` — message handed off to a background watcher;
    the reply will be POSTed to Feishu when the agent finishes (could
    be minutes later for heavy tool-running turns). Webhooks should
    ACK immediately, which is why this is fire-and-forget.
  - `{:ok, :ignored}` — event wasn't a chat message we care about
  - `{:error, reason}` — session resolution failed before we could
    spawn the watcher
  """
  def handle_event(payload, opts \\ [])

  def handle_event(
        %{"header" => %{"event_type" => "im.message.receive_v1"}, "event" => event},
        opts
      ) do
    with %{"message" => msg, "sender" => sender} <- event,
         %{"chat_id" => chat_id, "message_id" => message_id, "content" => content_json} <- msg,
         %{"sender_id" => %{"open_id" => open_id}} <- sender,
         {:ok, text} <- decode_text(content_json) do
      run_opts =
        Keyword.merge(opts,
          chat_id: chat_id,
          display_name: sender["sender_id"]["user_id"],
          metadata: %{"feishu_chat_id" => chat_id, "message_id" => message_id},
          on_complete: fn _bot_user, result ->
            case result do
              {:ok, %{text: text, tool_calls: tool_calls, ask: ask}} ->
                body = render_reply(text, tool_calls, ask)
                reply(message_id, body, opts)

              {:error, _e} ->
                :ignore
            end
          end
        )

      case Bots.run_async(:feishu, open_id, text, run_opts) do
        {:ok, _} -> {:ok, :accepted}
        {:error, _} = err -> err
      end
    else
      _ -> {:ok, :ignored}
    end
  end

  def handle_event(_, _opts), do: {:ok, :ignored}

  defp decode_text(content_json) when is_binary(content_json) do
    case Jason.decode(content_json) do
      {:ok, %{"text" => text}} when is_binary(text) -> {:ok, text}
      _ -> :error
    end
  end

  defp decode_text(_), do: :error

  defp render_reply(text, tool_calls, ask) do
    summary = Bots.summarize_tool_calls(tool_calls)
    base = [text, summary] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n\n---\n")
    if ask, do: base <> "\n\n❓ " <> (ask["question"] || ""), else: base
  end

  @doc """
  Push a collected `result` map to a Feishu user proactively (no
  inbound `message_id` to reply to). Used by
  `Long.Agent.Bots.Outbound` for scheduler-driven pushes.

  Routes through `POST /im/v1/messages?receive_id_type=open_id` with the
  user's `open_id` as the receive_id. Attachments aren't wired (Feishu
  uploads need a separate `im/v1/files` round-trip we haven't built),
  so only the text+ask portion is delivered.
  """
  @spec push(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def push(open_id, %{} = result, opts \\ []) when is_binary(open_id) do
    text = Map.get(result, :text, "") || ""
    ask = Map.get(result, :ask)
    body = render_reply(text, [], ask)

    if body == "" do
      :ok
    else
      case send(open_id, body, opts) do
        {:ok, _} -> :ok
        {:error, _} = e -> e
      end
    end
  end

  # ── HTTP ──────────────────────────────────────────────────────────────────

  @doc """
  POST a proactive text message to a Feishu user/chat. `receive_id_type`
  defaults to `open_id` but can be overridden via `opts[:receive_id_type]`
  (e.g. `"chat_id"` for group push).
  """
  @spec send(String.t(), String.t(), keyword()) ::
          {:ok, :sent} | {:error, term()}
  def send(receive_id, text, opts \\ []) do
    http = Keyword.get(opts, :http, &Req.request/1)
    receive_id_type = Keyword.get(opts, :receive_id_type, "open_id")

    with {:ok, token} <- tenant_token(http) do
      response =
        http.(
          method: :post,
          url: "#{@api_base}/im/v1/messages",
          params: %{receive_id_type: receive_id_type},
          headers: [{"authorization", "Bearer #{token}"}, {"content-type", "application/json"}],
          json: %{
            "receive_id" => receive_id,
            "msg_type" => "text",
            "content" => Jason.encode!(%{"text" => text})
          }
        )

      case response do
        {:ok, %Req.Response{status: 200, body: %{"code" => 0}}} -> {:ok, :sent}
        {:ok, %Req.Response{body: body}} -> {:error, {:feishu, body}}
        other -> {:error, other}
      end
    end
  end

  @doc "POST a reply to a specific Feishu message_id."
  def reply(message_id, text, opts \\ []) do
    http = Keyword.get(opts, :http, &Req.request/1)

    with {:ok, token} <- tenant_token(http) do
      response =
        http.(
          method: :post,
          url: "#{@api_base}/im/v1/messages/#{message_id}/reply",
          headers: [{"authorization", "Bearer #{token}"}, {"content-type", "application/json"}],
          json: %{
            "msg_type" => "text",
            "content" => Jason.encode!(%{"text" => text})
          }
        )

      case response do
        {:ok, %Req.Response{status: 200, body: %{"code" => 0}}} -> {:ok, :replied}
        {:ok, %Req.Response{body: body}} -> {:error, {:feishu, body}}
        other -> {:error, other}
      end
    end
  end

  defp tenant_token(http) do
    app_id = System.get_env("FEISHU_APP_ID")
    app_secret = System.get_env("FEISHU_APP_SECRET")

    cond do
      is_nil(app_id) or app_id == "" ->
        {:error, :missing_app_id}

      is_nil(app_secret) or app_secret == "" ->
        {:error, :missing_app_secret}

      true ->
        case http.(
               method: :post,
               url: @api_base <> @token_path,
               json: %{"app_id" => app_id, "app_secret" => app_secret}
             ) do
          {:ok, %Req.Response{status: 200, body: %{"code" => 0, "tenant_access_token" => t}}} ->
            {:ok, t}

          {:ok, %Req.Response{body: body}} ->
            {:error, {:feishu_token, body}}

          other ->
            {:error, other}
        end
    end
  end

  @doc "Verify the v2 webhook header `X-Lark-Signature` (`HMAC-SHA256` over timestamp+nonce+verification_token+body)."
  def valid_signature?(timestamp, nonce, body, signature) when is_binary(signature) do
    token = System.get_env("FEISHU_VERIFICATION_TOKEN") || ""
    base = timestamp <> nonce <> token <> body
    computed = :crypto.mac(:hmac, :sha256, token, base) |> Base.encode16(case: :lower)
    Plug.Crypto.secure_compare(computed, signature)
  end

  def valid_signature?(_, _, _, _), do: false
end
