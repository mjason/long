defmodule Long.Agent.Tools.UpdateWorkingCheckpoint do
  @moduledoc """
  Port of `do_update_working_checkpoint`. Persists the L1 "key info" snapshot
  for the current session via the Phase 0 `Long.Agent.upsert_checkpoint`
  action. Ephemeral sessions (no `session_id` in context) keep the value in
  the loop's in-memory state only.
  """

  @behaviour Long.Agent.Tool

  alias Long.Agent.{StepOutcome, Tool, ToolContext}

  @impl true
  def name, do: "update_working_checkpoint"

  @impl true
  def schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => name(),
        "description" =>
          "Update the working-memory checkpoint (L1). Use this to record the key facts/decisions " <>
            "that should survive across turns.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "key_info" => %{
              "type" => "string",
              "description" =>
                "Concise, durable summary of what matters for the rest of the task."
            }
          },
          "required" => ["key_info"]
        }
      }
    }
  end

  @impl true
  def run(args, %ToolContext{session_id: session_id}) do
    key_info = args["key_info"] || ""

    outcome =
      cond do
        session_id == nil ->
          # ephemeral — caller is expected to keep state itself
          StepOutcome.cont(%{"status" => "success", "stored" => :ephemeral})

        true ->
          case Long.Agent.upsert_checkpoint(%{session_id: session_id, key_info: key_info}) do
            {:ok, _cp} -> StepOutcome.cont(%{"status" => "success", "stored" => :persisted})
            {:error, e} -> StepOutcome.cont(%{"status" => "error", "msg" => inspect(e)})
          end
      end

    Tool.emit("[Info] Working checkpoint updated.\n", outcome)
  end
end
