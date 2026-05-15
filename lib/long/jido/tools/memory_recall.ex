defmodule Long.Jido.Tools.MemoryRecall do
  @moduledoc """
  Explicit memory lookup. Most of the time the agent gets relevant
  memories auto-injected into its system prompt at the start of each
  turn, but this tool exists when the agent needs to deliberately
  search for something specific (e.g. "what did I commit to do last
  week about the auth rewrite?").

  Searches `Long.Agent.SessionMemory` (current session) plus
  `Long.Agent.GlobalMemory`. Surfaced rows have their
  `hit_count`/`last_used_at` bumped so future ranking favours
  memories that actually got read.
  """

  use Jido.Action,
    name: "memory_recall",
    description: """
    Search saved memories by keywords. Returns up to `limit` matches
    ranked by relevance + importance + recency.

    `scope` defaults to both tiers; pass "session" or "global" to
    constrain.

    Note: the most relevant memories are usually already in your
    system prompt — only call this when you need to dig for
    something specific that wasn't auto-surfaced.
    """,
    category: "memory",
    tags: ["memory", "recall"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        query: Zoi.string(description: "Free-text keywords; case-insensitive"),
        scope:
          Zoi.string(description: "session | global (omit for both)")
          |> Zoi.optional(),
        limit:
          Zoi.integer(description: "Max matches; default 8")
          |> Zoi.optional()
          |> Zoi.default(8)
      })

  alias Long.Agent.Memory.Recall
  alias Long.Jido.Tools.Format

  @impl true
  def run(params, ctx) do
    query = params[:query] || ""

    if String.trim(query) == "" do
      {:ok, %{status: "error", msg: "query must not be empty"}}
    else
      hits =
        Recall.recall(query,
          scope: parse_scope(params[:scope]),
          session_id: ctx[:session_id],
          limit: params[:limit] || 8,
          bump: true
        )

      {:ok, %{status: "success", count: length(hits), matches: Enum.map(hits, &serialize/1)}}
    end
  end

  defp serialize(%{type: type, row: row, score: score}) do
    %{
      scope: to_string(type),
      key: row.key,
      value: row.value,
      kind: to_string(row.kind || :fact),
      importance: row.importance || 3,
      score: Float.round(score, 3),
      last_used_at: Format.iso8601(row.last_used_at)
    }
  end

  defp parse_scope("session"), do: :session
  defp parse_scope("global"), do: :global
  defp parse_scope(_), do: nil
end
