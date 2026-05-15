defmodule Long.Jido.Tools.SkillSearch do
  @moduledoc """
  Tier-L1 of skill progressive disclosure: keyword search the FS-backed
  skill index and return `name + description` (no body). Skill names are
  already in the system prompt addendum — call this when a name looks
  promising but the description would help confirm.
  """

  use Jido.Action,
    name: "skill_search",
    description:
      "Search registered skills by free-text query. Returns top matches " <>
        "with `name` and `description` only. Use `skill_read(name: …)` to " <>
        "fetch the full SKILL.md instructions once you've picked one.",
    category: "skill",
    tags: ["skill", "search"],
    vsn: "3.0.0",
    schema:
      Zoi.object(%{
        query: Zoi.string(description: "Natural-language search query"),
        limit: Zoi.integer(description: "Max hits (default 5)") |> Zoi.optional()
      })

  alias Long.Agent.Skill.Store

  @impl true
  def run(params, _ctx) do
    query = (params[:query] || params["query"] || "") |> to_string() |> String.trim()
    limit = params[:limit] || params["limit"] || 5

    if query == "" do
      {:ok, %{status: "error", msg: "query must not be empty"}}
    else
      hits = Store.search(query, limit: limit)

      {:ok,
       %{
         status: "success",
         query: query,
         results: Enum.map(hits, &to_payload/1)
       }}
    end
  end

  defp to_payload(%{row: s, score: score}) do
    %{
      name: s.name,
      description: s.description,
      tags: s.tags,
      use_count: s.use_count,
      score: Float.round(score, 2)
    }
  end
end
