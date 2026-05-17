defmodule Long.Agent.Enums.MemoryKind do
  @moduledoc """
  Shared enum for `SessionMemory.kind` and `GlobalMemory.kind`.
  Exposed as a proper GraphQL enum (`MEMORY_KIND`) instead of a
  loose String, so the LLM can introspect valid values.
  """
  use Ash.Type.Enum, values: [:fact, :preference, :goal, :decision]
  use AshGraphql.Type

  @impl true
  def graphql_type(_), do: :memory_kind
end
