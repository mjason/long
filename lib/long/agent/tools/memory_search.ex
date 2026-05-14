defmodule Long.Agent.Tools.MemorySearch do
  @moduledoc """
  Local skill search tool (replacement for the Python `skill_search` HTTP
  client). Ranks the L3 index by name / tag / description match plus a
  small recency + usage boost.
  """

  @behaviour Long.Agent.Tool

  alias Long.Agent.{Memory, StepOutcome, Tool, ToolContext}

  @impl true
  def name, do: "memory_search"

  @impl true
  def schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => name(),
        "description" =>
          "Search the L3 skill index by keywords. Returns up to `limit` skills " <>
            "ranked by name/tag/description match plus recent-use boost.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "default" => 10},
            "kind" => %{
              "type" => "string",
              "enum" => ["script_py", "sop_md", "template_py", "other"]
            }
          },
          "required" => ["query"]
        }
      }
    }
  end

  @impl true
  def run(args, %ToolContext{}) do
    query = args["query"] || ""
    limit = args["limit"] || 10
    kind = args["kind"] && String.to_atom(args["kind"])

    results = Memory.search_skills(query, limit: limit, kind: kind)

    payload = %{
      "query" => query,
      "matches" =>
        Enum.map(results, fn %{skill: s, score: score, reasons: reasons} ->
          %{
            "name" => s.name,
            "kind" => to_string(s.kind),
            "path" => s.relative_path,
            "sop_path" => s.sop_path,
            "description" => s.description,
            "tags" => s.tags,
            "use_count" => s.use_count,
            "score" => Float.round(score, 3),
            "reasons" => reasons
          }
        end)
    }

    Tool.emit(
      "[Info] memory_search '#{query}' → #{length(results)} hit(s)\n",
      StepOutcome.cont(payload)
    )
  end
end
