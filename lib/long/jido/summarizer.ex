defmodule Long.Jido.Summarizer do
  @moduledoc """
  LLM-driven compression of the older portion of a conversation. When
  the live history would blow the model's context window, callers feed
  the prefix here; we synthesize a concise text summary and the caller
  prepends it to the system prompt while continuing with only the
  recent tail in raw form.

  Mechanics: one synchronous `LLMCall.call/3` per compression cycle,
  no tools, low temperature. The new summary subsumes any prior
  summary that was passed in.
  """

  alias Long.Jido.LLMCall

  @system_prompt """
  You are summarizing an in-progress conversation between a user and
  an AI agent so the agent can continue working without the full
  history in context.

  Produce a concise, factual summary that captures:
    • The user's overarching goal and any pending sub-tasks
    • Important decisions, constraints, or preferences the user stated
    • Notable tool results future turns might reference (URLs visited,
      files produced, data extracted, errors encountered)
    • Current state of any task in progress

  Skip social niceties, redundant confirmations, and tool error noise
  that's already been resolved.  Plain text only — no markdown headings
  or lists.  Aim for under 800 words; shorter is better.

  If a "Previous summary" section is provided, your output should
  supersede it — fold any still-relevant points from the prior summary
  into the new one along with the new turns.
  """

  @doc """
  Produce a fresh summary that covers `prior_summary` (may be nil) plus
  the conversation rows in `rows` (oldest first). `llm_alias` selects
  the model.
  """
  @spec summarize(String.t() | nil, [map()], String.t()) :: {:ok, String.t()} | {:error, term()}
  def summarize(prior_summary, rows, llm_alias)
      when is_binary(llm_alias) and is_list(rows) and rows != [] do
    transcript = build_transcript(prior_summary, rows)

    messages = [
      ReqLLM.Context.system(@system_prompt),
      ReqLLM.Context.user(transcript)
    ]

    case LLMCall.call(messages, [], llm_alias: llm_alias, max_tokens: 1500, temperature: 0.2) do
      {:ok, %{text: text}} when is_binary(text) and text != "" ->
        {:ok, String.trim(text)}

      {:ok, _} ->
        {:error, :empty_summary}

      err ->
        err
    end
  end

  def summarize(_, [], _), do: {:error, :nothing_to_summarize}

  defp build_transcript(nil, rows) do
    "# Conversation to summarize:\n\n" <> render_rows(rows)
  end

  defp build_transcript(prior, rows) do
    """
    # Previous summary (carry forward what's still relevant):

    #{prior}

    # New turns to fold into the summary:

    #{render_rows(rows)}
    """
  end

  defp render_rows(rows) do
    Enum.map_join(rows, "\n\n", &render_row/1)
  end

  defp render_row(%{role: :user, content: content, tool_results: results}) do
    cond do
      is_list(results) and results != [] ->
        "[tool_result] " <>
          Enum.map_join(results, "\n", fn r ->
            "#{Map.get(r, "tool_use_id", "")}: #{truncate(Map.get(r, "content", ""), 500)}"
          end)

      true ->
        "[user] #{truncate(content || "", 1000)}"
    end
  end

  defp render_row(%{role: :assistant, content: content, tool_calls: calls}) do
    base = "[assistant] #{truncate(content || "", 1000)}"

    case calls do
      [_ | _] ->
        tools =
          Enum.map_join(calls, ", ", fn tc ->
            Map.get(tc, "name", "?") <> "(" <> inspect(Map.get(tc, "input", %{})) <> ")"
          end)

        base <> "\n  → tool_calls: " <> truncate(tools, 500)

      _ ->
        base
    end
  end

  defp render_row(%{role: role, content: content}) do
    "[#{role}] #{truncate(content || "", 500)}"
  end

  defp truncate(s, n) when is_binary(s) and byte_size(s) > n do
    Long.Util.Utf8.safe_truncate(s, n) <> "…"
  end

  defp truncate(s, _) when is_binary(s), do: s
  defp truncate(_, _), do: ""
end
