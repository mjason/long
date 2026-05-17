defmodule Long.Agent.Enums.MemoryScope do
  @moduledoc "Coarse bucket for `GlobalMemory.scope`."
  use Ash.Type.Enum, values: [:general, :insight]
  use AshGraphql.Type

  @impl true
  def graphql_type(_), do: :memory_scope
end
