defmodule Long.Agent.Enums.SessionStatus do
  @moduledoc "Lifecycle bucket for `Session.status`."
  use Ash.Type.Enum, values: [:active, :archived]
  use AshGraphql.Type

  @impl true
  def graphql_type(_), do: :session_status
end
