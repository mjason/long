defmodule LongWeb.InternalLLMController do
  @moduledoc """
  Internal LLM endpoint for sandboxed scripts (see `Long.Agent.LLMBridge`).
  A Deno/bash script POSTs `{prompt|messages, context, max_tokens?, temperature?}`
  with its per-run `x-llm-token`; we verify the token → session, run the
  completion through the app's configured model, and return `{text, usage}`.
  The API key never leaves the server.

  Auth is the signed, short-lived, session-scoped token — the only way to obtain
  one is to be inside a running sandbox (the token is injected per-run) or to
  hold the endpoint secret. That's a stronger gate than the rest of this
  LAN-trusted app (e.g. `/graphql` is unauthenticated), so we don't additionally
  pin the source IP: OrbStack routes the container's own `127.0.0.1` through its
  proxy, so a loopback check would reject the legitimate in-container caller.
  """
  use LongWeb, :controller

  require Logger

  alias Long.Agent.LLMBridge

  def complete(conn, params) do
    with {:ok, session_id} <- verify_token(conn),
         {:ok, %{text: text, usage: usage}} <- LLMBridge.complete(session_id, params) do
      json(conn, %{text: text, usage: usage})
    else
      {:error, reason} when reason in [:missing, :expired, :invalid] ->
        conn |> put_status(:unauthorized) |> json(%{error: "invalid or expired token"})

      {:error, :empty_prompt} ->
        conn |> put_status(:bad_request) |> json(%{error: "provide `prompt` or `messages`"})

      {:error, reason} ->
        Logger.warning("InternalLLM: completion failed: #{inspect(reason)}")
        conn |> put_status(:bad_gateway) |> json(%{error: "llm call failed"})
    end
  end

  defp verify_token(conn) do
    case get_req_header(conn, "x-llm-token") do
      [token | _] -> LLMBridge.verify(token)
      _ -> {:error, :missing}
    end
  end
end
