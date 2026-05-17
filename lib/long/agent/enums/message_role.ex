defmodule Long.Agent.Enums.MessageRole do
  @moduledoc "Conversation role for `Message.role`."
  use Ash.Type.Enum, values: [:system, :user, :assistant, :tool]
  use AshGraphql.Type

  @impl true
  def graphql_type(_), do: :message_role
end
