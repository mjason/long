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

  - `{:ok, :replied}` — message handled and reply dispatched
  - `{:ok, :ignored}` — event wasn't a chat message we care about
  - `{:error, reason}`
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
          metadata: %{"feishu_chat_id" => chat_id, "message_id" => message_id}
        )

      task = Task.async(fn -> Bots.run_and_collect(:feishu, open_id, text, run_opts) end)

      case Task.yield(task, Keyword.get(opts, :timeout, 60_000)) || Task.shutdown(task) do
        {:ok, {:ok, %{text: text, tool_calls: tool_calls, ask: ask}}} ->
          body = render_reply(text, tool_calls, ask)
          reply(message_id, body, opts)

        {:ok, {:error, e}} ->
          {:error, e}

        nil ->
          {:error, :timeout}

        other ->
          {:error, other}
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

  # ── HTTP ──────────────────────────────────────────────────────────────────

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
