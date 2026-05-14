defmodule Long.Jido.Tools.MemorySearch do
  @moduledoc "Jido.Action port of `Long.Agent.Tools.MemorySearch`. Local L3 skill search."

  use Jido.Action,
    name: "memory_search",
    description:
      "Search the L3 skill index by keywords. Returns up to `limit` skills ranked " <>
        "by name/tag/description match plus recent-use boost.",
    category: "memory",
    tags: ["memory", "l3", "search"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        query: Zoi.string(description: "Search keywords"),
        limit: Zoi.integer() |> Zoi.optional() |> Zoi.default(10),
        kind:
          Zoi.string(description: "script_py | sop_md | template_py | other")
          |> Zoi.optional()
      })

  alias Long.Agent.Memory

  @impl true
  def run(params, _ctx) do
    query = params[:query] || ""
    limit = params[:limit] || 10
    kind = parse_kind(params[:kind])

    results = Memory.search_skills(query, limit: limit, kind: kind)

    {:ok,
     %{
       query: query,
       matches:
         Enum.map(results, fn %{skill: s, score: score, reasons: reasons} ->
           %{
             name: s.name,
             kind: to_string(s.kind),
             path: s.relative_path,
             sop_path: s.sop_path,
             description: s.description,
             tags: s.tags,
             use_count: s.use_count,
             score: Float.round(score, 3),
             reasons: reasons
           }
         end)
     }}
  end

  defp parse_kind("script_py"), do: :script_py
  defp parse_kind("sop_md"), do: :sop_md
  defp parse_kind("template_py"), do: :template_py
  defp parse_kind("other"), do: :other
  defp parse_kind(_), do: nil
end
