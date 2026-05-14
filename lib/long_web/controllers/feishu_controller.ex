defmodule LongWeb.FeishuController do
  @moduledoc """
  Phoenix entry-point for Feishu (Lark) webhooks. Handles:

  - The URL verification challenge during bot setup
  - `im.message.receive_v1` events: forwards to `Long.Agent.Bots.Feishu`
  - Rejects events whose signature header doesn't match the configured
    verification token (if `FEISHU_VERIFICATION_TOKEN` is set)

  Mount in router.ex with:

      pipeline :api do
        plug :accepts, ["json"]
      end

      scope "/webhooks/feishu", LongWeb do
        pipe_through :api
        post "/", FeishuController, :receive
      end
  """

  use LongWeb, :controller

  alias Long.Agent.Bots.Feishu

  def receive(conn, %{"type" => "url_verification"} = params) do
    json(conn, Feishu.handle_verification(params))
  end

  def receive(conn, params) do
    if signature_valid?(conn, params) do
      # Hand off async so we acknowledge fast (Feishu expects <3s response).
      Task.start(fn -> Feishu.handle_event(params) end)
      json(conn, %{"code" => 0, "msg" => "ok"})
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{"code" => 1, "msg" => "bad signature"})
    end
  end

  defp signature_valid?(conn, params) do
    case System.get_env("FEISHU_VERIFICATION_TOKEN") do
      nil ->
        # No token configured → accept everything (dev mode)
        true

      "" ->
        true

      _token ->
        with [signature] <- get_req_header(conn, "x-lark-signature"),
             [timestamp] <- get_req_header(conn, "x-lark-request-timestamp"),
             [nonce] <- get_req_header(conn, "x-lark-request-nonce") do
          body = Jason.encode!(params)
          Feishu.valid_signature?(timestamp, nonce, body, signature)
        else
          _ -> false
        end
    end
  end
end
