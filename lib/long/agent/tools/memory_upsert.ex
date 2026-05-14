defmodule Long.Agent.Tools.MemoryUpsert do
  @moduledoc """
  Upsert an L2 global memory entry. The Python version stores L2 as
  `memory/global_mem.txt` and updates it via `file_patch`; this tool gives
  the agent a structured `(scope, key, value)` shape so the model can edit
  one entry without rewriting the whole file.
  """

  @behaviour Long.Agent.Tool

  alias Long.Agent.{StepOutcome, Tool, ToolContext}

  @impl true
  def name, do: "memory_upsert"

  @impl true
  def schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => name(),
        "description" =>
          "Upsert an L2 global memory entry. Use scope `:insight` for distilled lessons learned, " <>
            "`:general` for facts the agent should remember across turns.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "scope" => %{
              "type" => "string",
              "enum" => ["general", "insight"],
              "default" => "general"
            },
            "key" => %{"type" => "string"},
            "value" => %{"type" => "string"}
          },
          "required" => ["key", "value"]
        }
      }
    }
  end

  @impl true
  def run(args, %ToolContext{}) do
    scope = parse_scope(args["scope"])
    key = args["key"] || ""
    value = args["value"] || ""

    outcome =
      cond do
        key == "" ->
          StepOutcome.cont(%{"status" => "error", "msg" => "key must not be empty"})

        true ->
          case Long.Agent.put_global_memory(%{scope: scope, key: key, value: value}) do
            {:ok, row} ->
              StepOutcome.cont(%{
                "status" => "success",
                "scope" => to_string(row.scope),
                "key" => row.key
              })

            {:error, e} ->
              StepOutcome.cont(%{"status" => "error", "msg" => inspect(e)})
          end
      end

    Tool.emit("[Info] memory_upsert(#{scope}, #{key})\n", outcome)
  end

  defp parse_scope("insight"), do: :insight
  defp parse_scope(_), do: :general
end
