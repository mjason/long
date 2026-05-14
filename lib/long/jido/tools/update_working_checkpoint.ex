defmodule Long.Jido.Tools.UpdateWorkingCheckpoint do
  @moduledoc """
  Jido.Action port of `Long.Agent.Tools.UpdateWorkingCheckpoint`. Persists
  the L1 working memory checkpoint when ctx carries a `:session_id`;
  otherwise it stays in-memory only.
  """

  use Jido.Action,
    name: "update_working_checkpoint",
    description:
      "Update the L1 working-memory checkpoint with a concise summary of facts/decisions " <>
        "to remember across turns.",
    category: "memory",
    tags: ["memory", "l1"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        key_info: Zoi.string(description: "Concise summary to remember")
      })

  @impl true
  def run(params, ctx) do
    key_info = params[:key_info] || ""
    session_id = ctx[:session_id]

    cond do
      session_id == nil ->
        {:ok, %{status: "success", stored: "ephemeral"}}

      true ->
        case Long.Agent.upsert_checkpoint(%{session_id: session_id, key_info: key_info}) do
          {:ok, _cp} -> {:ok, %{status: "success", stored: "persisted"}}
          {:error, e} -> {:ok, %{status: "error", msg: inspect(e)}}
        end
    end
  end
end
