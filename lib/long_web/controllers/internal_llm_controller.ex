defmodule LongWeb.InternalLLMController do
  @moduledoc """
  Loopback-only LLM endpoint for sandboxed scripts (see `Long.Agent.LLMBridge`).
  A Deno/bash script POSTs `{prompt|messages, context, max_tokens?, temperature?}`
  with its per-run `x-llm-token`; we verify the token → session, run the
  completion through the app's configured model, and return `{text, usage}`.
  The API key never leaves the server.
  """
  use LongWeb, :controller

  require Logger

  alias Long.Agent.LLMBridge

  def complete(conn, params) do
    with :ok <- ensure_loopback(conn),
         {:ok, session_id} <- verify_token(conn),
         {:ok, %{text: text, usage: usage}} <- LLMBridge.complete(session_id, params) do
      json(conn, %{text: text, usage: usage})
    else
      {:error, :not_loopback} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

      {:error, reason} when reason in [:missing, :expired, :invalid] ->
        conn |> put_status(:unauthorized) |> json(%{error: "invalid or expired token"})

      {:error, :empty_prompt} ->
        conn |> put_status(:bad_request) |> json(%{error: "provide `prompt` or `messages`"})

      {:error, reason} ->
        Logger.warning("InternalLLM: completion failed: #{inspect(reason)}")
        conn |> put_status(:bad_gateway) |> json(%{error: "llm call failed"})
    end
  end

  # Only reachable from inside the container (the sandbox fetches localhost).
  # A LAN request to :4000/internal/llm is rejected even with a token.
  defp ensure_loopback(conn) do
    case conn.remote_ip do
      {127, 0, 0, 1} -> :ok
      {0, 0, 0, 0, 0, 0, 0, 1} -> :ok
      _ -> {:error, :not_loopback}
    end
  end

  defp verify_token(conn) do
    case get_req_header(conn, "x-llm-token") do
      [token | _] -> LLMBridge.verify(token)
      _ -> {:error, :missing}
    end
  end
end
