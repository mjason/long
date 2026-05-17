defmodule Long.Agent.Enums.BotPlatform do
  @moduledoc """
  External chat platform identifier for `BotUser.platform`. Only the
  platforms with an actual outbound adapter (see `Long.Agent.Bots.Outbound`)
  are listed — adding a value here without an adapter creates rows the
  bot pipeline can't reply to.
  """
  use Ash.Type.Enum, values: [:telegram, :feishu, :wechat]
  use AshGraphql.Type

  @impl true
  def graphql_type(_), do: :bot_platform
end
