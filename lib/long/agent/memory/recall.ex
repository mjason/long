defmodule Long.Agent.Memory.Recall do
  @moduledoc """
  Keyword-scored retrieval over `Long.Agent.SessionMemory` (current
  session) + `Long.Agent.GlobalMemory` (cross-session). Returns a
  merged ranked list shaped for either the `memory_recall` tool
  response or the system-prompt auto-injection at Loop entry.

  Scoring is case-insensitive substring overlap on `key`/`value` plus
  importance + recency boosts.

  Side effect: when memories are surfaced, callers can opt into
  bumping `hit_count` + `last_used_at` so future ranking can favour
  the memories that actually got read.
  """

  alias Long.Agent
  alias Long.Agent.{GlobalMemory, SessionMemory}

  @type hit :: %{
          type: :session | :global,
          row: GlobalMemory.t() | SessionMemory.t(),
          score: float()
        }

  @doc """
  Top-`:limit` memories that match `query` from both session and
  global tiers. Pass `:session_id` to include session-scoped rows;
  otherwise only global memory is searched.

  Set `:bump` to true to update `last_used_at` + `hit_count` on every
  returned row.
  """
  @spec recall(String.t(), keyword()) :: [hit()]
  def recall(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 8)
    session_id = Keyword.get(opts, :session_id)
    bump? = Keyword.get(opts, :bump, false)
    scope_filter = Keyword.get(opts, :scope)

    needles = normalize(query)

    session_hits =
      if session_id && scope_filter != :global do
        session_id |> load_session_memory() |> score_each(needles, :session)
      else
        []
      end

    global_hits =
      if scope_filter != :session do
        load_global_memory() |> score_each(needles, :global)
      else
        []
      end

    hits =
      (session_hits ++ global_hits)
      |> Enum.reject(&(&1.score <= 0))
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(limit)

    if bump?, do: Enum.each(hits, &bump/1)
    hits
  end

  @doc """
  Format a list of hits into a multi-line addendum the Loop will fold
  into the system prompt. Empty input → empty string so the caller
  can concatenate safely.
  """
  @spec format_for_prompt([hit()]) :: String.t()
  def format_for_prompt([]), do: ""

  def format_for_prompt(hits) do
    lines = Enum.map_join(hits, "\n", &format_line/1)
    "# Relevant memory (auto-recalled)\n\n" <> lines
  end

  defp format_line(%{type: type, row: row}) do
    tag =
      case type do
        :session -> "session"
        :global -> "global/#{row.scope}"
      end

    "- [#{tag}] #{row.key}: #{row.value}"
  end

  # ── ranking ──────────────────────────────────────────────────────────

  defp normalize(query), do: Long.Util.Search.normalize(query)

  defp score_each(rows, needles, type) do
    Enum.map(rows, fn r ->
      %{type: type, row: r, score: score_row(r, needles)}
    end)
  end

  defp score_row(row, needles) do
    key = String.downcase(row.key || "")
    val = String.downcase(row.value || "")

    keyword_score =
      Enum.reduce(needles, 0.0, fn n, acc ->
        cond do
          String.contains?(key, n) -> acc + 3.0
          String.contains?(val, n) -> acc + 1.0
          true -> acc
        end
      end)

    keyword_score + importance_boost(row.importance) + recency_boost(row.last_used_at)
  end

  defp importance_boost(nil), do: 0.0
  defp importance_boost(n) when is_integer(n) and n >= 1 and n <= 5, do: (n - 3) * 0.5
  defp importance_boost(_), do: 0.0

  defp recency_boost(ts), do: Long.Util.Search.recency_boost(ts)

  # ── data access ─────────────────────────────────────────────────────

  defp load_session_memory(session_id) do
    case Agent.list_session_memory_for(session_id) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp load_global_memory do
    case Agent.list_global_memory() do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp bump(%{type: :session, row: row}), do: Agent.bump_session_memory_usage(row)
  defp bump(%{type: :global, row: row}), do: Agent.bump_global_memory_usage(row)
end
