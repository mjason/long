defmodule Long.Agent.Enums.ScheduledTaskRepeat do
  @moduledoc "Cadence for `ScheduledTask.repeat`."
  use Ash.Type.Enum,
    values: [:once, :daily, :weekday, :weekly, :monthly, :every_n_hours, :every_n_minutes]

  use AshGraphql.Type

  @impl true
  def graphql_type(_), do: :scheduled_task_repeat
end
