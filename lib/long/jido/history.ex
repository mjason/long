defmodule Long.Jido.History do
  @moduledoc """
  Loads persisted `Long.Agent.Message` rows for a session and converts
  them into a `ReqLLM.Message` list suitable for prepending to
  `Long.Jido.Loop`'s initial context, so the agent has memory across
  user messages.

  Compression strategy (high-water / low-water):

    * Each session may carry a stored `:summary` covering all messages
      with `inserted_at <= :summary_through_inserted_at` (both fields
      on `Long.Agent.Session`).
    * On every load we read all messages, drop those already covered
      by the prior summary, and measure remaining size.
    * If the tail is under `@high_water_chars` (default 30K), we return
      it verbatim alongside the existing summary.
    * If the tail exceeds the high-water mark, we ask
      `Long.Jido.Summarizer` to fold the oldest portion of the tail
      into a fresh summary that supersedes the prior one, persist it,
      and return only the recent portion (≤ `@low_water_chars`) as raw
      context.

  Tool-call ↔ tool-result pairing is preserved when we choose where to
  cut the tail — the OpenAI/Anthropic APIs reject orphaned tool_calls.
  """

  alias Long.Agent
  alias Long.Jido.Summarizer
  alias Long.Util.Utf8

  @high_water_chars 30_000
  @low_water_chars 15_000

  @doc """
  Plain load with no compression — used by tests that exercise just
  the row→ReqLLM conversion path. Production callers should prefer
  `load_or_compress/3`.
  """
  @spec load(String.t(), keyword()) :: [ReqLLM.Message.t()]
  def load(session_id, opts \\ []) do
    exclude_id = Keyword.get(opts, :exclude_id)
    max_chars = Keyword.get(opts, :max_chars, @high_water_chars)

    case Agent.list_messages_for_session(session_id) do
      {:ok, rows} ->
        rows
        |> Enum.reject(&(&1.id == exclude_id))
        |> trim_to_budget(max_chars)
        |> rows_to_req_messages()

      _ ->
        []
    end
  end

  @doc """
  History + on-demand LLM compression.

  Returns `%{system_addendum: nil | String.t(), messages: [ReqLLM.Message.t()]}`.

  - `system_addendum` is the (existing or freshly-generated) summary
    text the Loop should fold into the system prompt; nil means no
    summary applies yet.
  - `messages` is the raw conversation tail, in chronological order.

  Side effect: when a new summary is generated, it's persisted to
  `session.summary` + `session.summary_through_inserted_at` so the
  next call avoids the LLM round-trip.
  """
  @spec load_or_compress(String.t(), String.t() | nil, keyword()) ::
          %{system_addendum: String.t() | nil, messages: [ReqLLM.Message.t()]}
  def load_or_compress(session_id, llm_alias, opts \\ []) do
    high = Keyword.get(opts, :high_water, @high_water_chars)
    low = Keyword.get(opts, :low_water, @low_water_chars)
    exclude_id = Keyword.get(opts, :exclude_id)
    summarizer = Keyword.get(opts, :summarizer, &Summarizer.summarize/3)

    with {:ok, session} <- Agent.get_session(session_id),
         {:ok, rows} <- Agent.list_messages_for_session(session_id) do
      rows = Enum.reject(rows, &(&1.id == exclude_id))
      tail = drop_summarized(rows, session.summary_through_inserted_at)
      tail_chars = total_chars(tail)

      cond do
        tail_chars <= high ->
          %{system_addendum: session.summary, messages: tail_to_req(tail)}

        true ->
          maybe_compress(session, tail, low, llm_alias, summarizer)
      end
    else
      _ -> %{system_addendum: nil, messages: []}
    end
  end

  # ── compression ──────────────────────────────────────────────────────

  defp maybe_compress(_session, _tail, _low, nil, _summarizer) do
    # No LLM available to summarize; bail out empty so the Loop still
    # works (it'll see no history, which is bad but not crashing).
    %{system_addendum: nil, messages: []}
  end

  defp maybe_compress(session, tail, low, llm_alias, summarizer) do
    {to_fold, to_keep} = split_for_compression(tail, low)

    case safe_summarize(summarizer, session.summary, to_fold, llm_alias) do
      {:ok, new_summary} when is_binary(new_summary) ->
        through = last_inserted_at(to_fold) || session.summary_through_inserted_at
        persist_summary(session, new_summary, through)
        %{system_addendum: new_summary, messages: tail_to_req(to_keep)}

      _ ->
        # Summarization failed (LLM relay error, transient network,
        # raise from a buggy summarizer …) — fall back to a hard char
        # cap so the conversation still goes through. The prior summary
        # stays in effect; we just skip rolling it forward this turn.
        capped = trim_to_budget(tail, low)
        %{system_addendum: session.summary, messages: tail_to_req(capped)}
    end
  end

  defp safe_summarize(summarizer, prior, rows, llm_alias) do
    summarizer.(prior, rows, llm_alias)
  rescue
    e ->
      require Logger

      Logger.warning(
        "History: summarizer raised, falling back to hard trim. " <>
          "Reason: #{Exception.message(e)}"
      )

      _ =
        ErrorTracker.report(e, __STACKTRACE__, %{
          source: "history.summarize",
          llm_alias: llm_alias,
          row_count: length(rows)
        })

      {:error, e}
  end

  # Split `tail` into {to_fold_into_summary, to_keep_as_raw}. We choose
  # the cutoff such that `to_keep` is ≤ `low` chars; everything older
  # gets summarized. Then walk back from the cutoff to avoid landing
  # between an assistant tool_calls and its tool_result follow-ups.
  defp split_for_compression(tail, low) do
    indexed = Enum.with_index(tail)
    cut_idx = find_cut_index(Enum.reverse(indexed), 0, low, length(tail))
    cut_idx = align_to_pair_boundary(tail, cut_idx)
    Enum.split(tail, cut_idx)
  end

  defp find_cut_index([], _used, _low, idx), do: idx

  defp find_cut_index([{row, ri} | rest], used, low, idx) do
    cost = row_chars(row)

    if used + cost > low do
      idx
    else
      find_cut_index(rest, used + cost, low, ri)
    end
  end

  # Don't cut between an assistant message with tool_calls and the
  # tool_result rows that satisfy those calls.
  defp align_to_pair_boundary(tail, cut) do
    case Enum.at(tail, cut - 1) do
      %{role: :assistant, tool_calls: [_ | _]} -> align_to_pair_boundary(tail, cut - 1)
      _ -> max(cut, 0)
    end
  end

  defp persist_summary(session, summary, through) do
    Agent.update_session(session, %{
      summary: summary,
      summary_through_inserted_at: through
    })
  end

  defp last_inserted_at([]), do: nil
  defp last_inserted_at(rows), do: List.last(rows).inserted_at

  # ── tail helpers ─────────────────────────────────────────────────────

  defp drop_summarized(rows, nil), do: rows

  defp drop_summarized(rows, through) do
    Enum.drop_while(rows, fn r -> DateTime.compare(r.inserted_at, through) != :gt end)
  end

  defp tail_to_req(rows), do: rows_to_req_messages(rows)

  # Convert DB rows to ReqLLM messages, then defensively pair every
  # assistant `tool_calls` entry with a matching `:tool` message. If the
  # DB is missing a tool_result row (silent persist failure, ordering
  # tie, or pre-existing corruption), the OpenAI/Anthropic APIs reject
  # the whole request with "No tool output found for function call …".
  # We synthesize a placeholder error tool_result for any orphan so the
  # request stays valid and the LLM can recover gracefully.
  defp rows_to_req_messages(rows) do
    rows
    |> Enum.flat_map(&to_req_messages/1)
    |> repair_tool_call_pairing()
  end

  defp repair_tool_call_pairing(messages) do
    {acc, pending} = Enum.reduce(messages, {[], []}, &pair_step/2)
    acc |> flush_pending(pending) |> Enum.reverse()
  end

  defp pair_step(%ReqLLM.Message{role: :assistant, tool_calls: [_ | _] = calls} = msg, {acc, pending}) do
    ids = Enum.map(calls, & &1.id)
    {[msg | flush_pending(acc, pending)], ids}
  end

  defp pair_step(%ReqLLM.Message{role: :tool, tool_call_id: id} = msg, {acc, pending}) do
    cond do
      id in pending -> {[msg | acc], List.delete(pending, id)}
      # Orphan tool_result (no preceding tool_call in history) — drop.
      true -> {acc, pending}
    end
  end

  defp pair_step(msg, {acc, pending}) do
    {[msg | flush_pending(acc, pending)], []}
  end

  defp flush_pending(acc, []), do: acc

  defp flush_pending(acc, ids) do
    Enum.reduce(ids, acc, fn id, a ->
      [ReqLLM.Context.tool_result(id, ~s({"error":"tool result missing"})) | a]
    end)
  end

  defp total_chars(rows), do: Enum.reduce(rows, 0, fn r, acc -> acc + row_chars(r) end)

  # ── trimming (used by plain load/2 and as fallback) ──────────────────

  defp trim_to_budget(rows, max_chars) do
    total = total_chars(rows)

    if total <= max_chars do
      rows
    else
      rows
      |> Enum.reverse()
      |> take_within_budget([], 0, max_chars)
      |> Enum.reverse()
      |> drop_orphaned_tool_results()
    end
  end

  defp take_within_budget([], acc, _used, _max), do: acc

  defp take_within_budget([row | rest], acc, used, max) do
    cost = row_chars(row)

    if used + cost > max do
      acc
    else
      take_within_budget(rest, [row | acc], used + cost, max)
    end
  end

  defp drop_orphaned_tool_results(rows) do
    Enum.drop_while(rows, &tool_result_row?/1)
  end

  defp tool_result_row?(%{role: :user, tool_results: results}) when is_list(results) and results != [],
    do: true

  defp tool_result_row?(_), do: false

  # ── DB row → ReqLLM messages ────────────────────────────────────────

  defp row_chars(row) do
    base = String.length(row.content || "")
    extras = row.tool_calls |> List.wrap() |> Enum.reduce(0, &(&2 + tool_call_chars(&1)))
    results = row.tool_results |> List.wrap() |> Enum.reduce(0, &(&2 + tool_result_chars(&1)))
    base + extras + results
  end

  defp tool_call_chars(%{} = tc) do
    name = Map.get(tc, "name", "") |> to_string()
    input = Map.get(tc, "input", %{}) |> inspect()
    String.length(name) + String.length(input)
  end

  defp tool_result_chars(%{} = tr) do
    content = Map.get(tr, "content", "") |> to_string()
    String.length(content)
  end

  defp to_req_messages(%{role: :user, tool_results: [_ | _] = results}) do
    Enum.map(results, fn r ->
      id = Map.get(r, "tool_use_id") || Map.get(r, "id") || ""
      content = Map.get(r, "content", "") |> Utf8.sanitize()
      ReqLLM.Context.tool_result(id, content)
    end)
  end

  defp to_req_messages(%{role: :user, content: content}) when is_binary(content) do
    [ReqLLM.Context.user(Utf8.sanitize(content))]
  end

  defp to_req_messages(%{role: :assistant, content: content, tool_calls: calls})
       when is_list(calls) and calls != [] do
    req_calls =
      Enum.map(calls, fn tc ->
        id = Map.get(tc, "id", "")
        name = Map.get(tc, "name", "")
        input = Map.get(tc, "input", %{}) |> Jason.encode!()
        ReqLLM.ToolCall.new(id, name, input)
      end)

    [ReqLLM.Context.assistant(Utf8.sanitize(content || ""), tool_calls: req_calls)]
  end

  defp to_req_messages(%{role: :assistant, content: content}) when is_binary(content) do
    [ReqLLM.Context.assistant(Utf8.sanitize(content))]
  end

  defp to_req_messages(_), do: []
end
