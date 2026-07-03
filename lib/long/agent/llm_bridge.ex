defmodule Long.Agent.LLMBridge do
  @moduledoc """
  Lets sandboxed Deno/bash scripts (code_run, skills, monitors) run an LLM call
  through the app's configured model — WITHOUT ever seeing an API key.

  A per-run signed token (injected into the sandbox env as `LONG_LLM_TOKEN`,
  alongside `LONG_LLM_URL`) identifies the session. The script POSTs to the
  token-authed `/internal/llm` endpoint, which verifies the token and calls
  `complete/2` here. The model + credentials come from the DB (`LLMConfig`), so
  the key stays server-side.

  Two context modes — **both read-only on the conversation**; nothing is written
  back to the session transcript:

    * `"new"` — a blank one-shot completion (just the script's prompt/messages).
    * `"current"` — reasons WITH the user's current context (L1/L2 memory +
      recent chat history), then returns a conclusion. Surfacing that conclusion
      to the user is a separate, explicit push (like a monitor) — the reasoning
      never joins the chat.
  """
  require Ash.Query
  require Logger

  alias Long.Agent
  alias Long.Agent.Memory
  alias Long.Jido.LLMCall

  @salt "deno-llm"
  # A code_run / monitor run is bounded well under this; the token is useless
  # once the run ends.
  @token_ttl 300
  @max_tokens_cap 2048
  @history_limit 20

  # ── per-run token (injected into the sandbox env) ────────────────────

  @doc "Env vars to inject into a sandbox child so its scripts can call the LLM."
  @spec deno_env(String.t() | nil) :: [{charlist(), charlist()}]
  def deno_env(session_id) when is_binary(session_id) and session_id != "" do
    [
      {~c"LONG_LLM_TOKEN", String.to_charlist(sign(session_id))},
      {~c"LONG_LLM_URL", String.to_charlist(url())}
    ]
  end

  def deno_env(_), do: []

  @spec sign(String.t()) :: String.t()
  def sign(session_id),
    do: Phoenix.Token.sign(LongWeb.Endpoint, @salt, %{session_id: session_id})

  @spec verify(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(LongWeb.Endpoint, @salt, token, max_age: @token_ttl) do
      {:ok, %{session_id: sid}} when is_binary(sid) -> {:ok, sid}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid}
    end
  end

  def verify(_), do: {:error, :missing}

  # ── completion ───────────────────────────────────────────────────────

  @doc """
  Run one LLM completion for `session_id` with the given request params
  (`"prompt"` or `"messages"`, `"context"`, `"max_tokens"`, `"temperature"`).
  Read-only: never writes to the conversation.
  """
  @spec complete(String.t(), map()) :: {:ok, %{text: String.t(), usage: map()}} | {:error, term()}
  def complete(session_id, params) when is_binary(session_id) do
    case user_messages(params) do
      [] ->
        {:error, :empty_prompt}

      user_msgs ->
        messages = context_messages(params["context"], session_id) ++ user_msgs

        opts = [
          llm_alias: Agent.default_llm_alias(),
          max_tokens: clamp_tokens(params["max_tokens"]),
          temperature: clamp_temp(params["temperature"])
        ]

        case LLMCall.call(messages, [], opts) do
          {:ok, %{text: text, usage: usage}} -> {:ok, %{text: text || "", usage: usage || %{}}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # "current": the user's memory (L1/L2) + recent chat, as read-only context.
  defp context_messages("current", session_id) when is_binary(session_id) do
    framing =
      "You are a background helper for an ongoing conversation. Below is the " <>
        "user's memory and the recent chat — use it as context and answer the " <>
        "request directly with a conclusion. You have no tools, and your reply is " <>
        "NOT shown to the user unless the calling script forwards it."

    system =
      [framing, Memory.build_system_prompt(session_id)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    [ReqLLM.Context.system(system) | recent_history(session_id)]
  end

  defp context_messages(_new_or_nil, _session_id), do: []

  defp recent_history(session_id) do
    Long.Agent.Message
    |> Ash.Query.filter(session_id == ^session_id and internal == false and role in [:user, :assistant])
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(@history_limit)
    |> Ash.read!(authorize?: false)
    |> Enum.reverse()
    |> Enum.flat_map(&history_message/1)
  rescue
    e ->
      Logger.warning("LLMBridge: history load failed for #{session_id}: #{inspect(e)}")
      []
  end

  defp history_message(%{role: :user, content: c}) when is_binary(c) and c != "",
    do: [ReqLLM.Context.user(c)]

  defp history_message(%{role: :assistant, content: c}) when is_binary(c) and c != "",
    do: [ReqLLM.Context.assistant(c)]

  defp history_message(_), do: []

  # ── request parsing ──────────────────────────────────────────────────

  defp user_messages(%{"messages" => msgs}) when is_list(msgs), do: Enum.flat_map(msgs, &to_message/1)
  defp user_messages(%{"prompt" => p}) when is_binary(p) and p != "", do: [ReqLLM.Context.user(p)]
  defp user_messages(_), do: []

  defp to_message(%{"role" => "system", "content" => c}) when is_binary(c) and c != "",
    do: [ReqLLM.Context.system(c)]

  defp to_message(%{"role" => "assistant", "content" => c}) when is_binary(c) and c != "",
    do: [ReqLLM.Context.assistant(c)]

  defp to_message(%{"content" => c}) when is_binary(c) and c != "", do: [ReqLLM.Context.user(c)]
  defp to_message(_), do: []

  defp clamp_tokens(n) when is_integer(n) and n > 0, do: min(n, @max_tokens_cap)
  defp clamp_tokens(_), do: 1024

  defp clamp_temp(t) when is_number(t) and t >= 0 and t <= 2, do: t
  defp clamp_temp(_), do: 0.5

  defp url do
    port = LongWeb.Endpoint.config(:http)[:port] || 4000
    "http://127.0.0.1:#{port}/internal/llm"
  end
end
