defmodule Long.Agent.Enums.TurnStage do
  @moduledoc "Server state-machine stage for `TurnSnapshot.stage`."
  use Ash.Type.Enum, values: [:idle, :calling_llm, :running_tools, :asked_user, :done]
  use AshGraphql.Type

  @impl true
  def graphql_type(_), do: :turn_stage
end
