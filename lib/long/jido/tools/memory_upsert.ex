defmodule Long.Jido.Tools.MemoryUpsert do
  @moduledoc "Jido.Action port of `Long.Agent.Tools.MemoryUpsert`. Upsert an L2 global memory entry."

  use Jido.Action,
    name: "memory_upsert",
    description:
      "Upsert an L2 global memory entry. Use scope `:insight` for distilled lessons, " <>
        "`:general` for facts the agent should remember.",
    category: "memory",
    tags: ["memory", "l2"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        scope:
          Zoi.string(description: "general | insight")
          |> Zoi.optional()
          |> Zoi.default("general"),
        key: Zoi.string(),
        value: Zoi.string()
      })

  @impl true
  def run(params, _ctx) do
    scope = parse_scope(params[:scope])
    key = params[:key] || ""
    value = params[:value] || ""

    cond do
      key == "" ->
        {:ok, %{status: "error", msg: "key must not be empty"}}

      true ->
        case Long.Agent.put_global_memory(%{scope: scope, key: key, value: value}) do
          {:ok, row} -> {:ok, %{status: "success", scope: to_string(row.scope), key: row.key}}
          {:error, e} -> {:ok, %{status: "error", msg: inspect(e)}}
        end
    end
  end

  defp parse_scope("insight"), do: :insight
  defp parse_scope(_), do: :general
end
