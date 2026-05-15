defmodule Long.Jido.Tools.ListScheduledTasks do
  @moduledoc """
  List scheduled tasks belonging to the current session. The agent uses
  this to inspect what it has already queued before adding or cancelling.
  """

  use Jido.Action,
    name: "list_scheduled_tasks",
    description:
      "List scheduled tasks attached to THIS session. Returns name, prompt, " <>
        "repeat cadence, next_run_at and enabled flag for each.",
    category: "scheduling",
    tags: ["cron", "timer", "scheduler"],
    vsn: "1.0.0",
    schema: Zoi.object(%{})

  alias Long.Agent
  alias Long.Jido.Tools.Format

  @impl true
  def run(_params, ctx) do
    with {:ok, session_id} <- Format.require_session_id(ctx),
         {:ok, tasks} <- Agent.list_scheduled_tasks_for_session(session_id) do
      {:ok, %{status: "success", count: length(tasks), tasks: Enum.map(tasks, &serialize/1)}}
    else
      {:error, e} when is_binary(e) -> {:ok, %{status: "error", msg: e}}
      {:error, e} -> {:ok, %{status: "error", msg: inspect(e)}}
    end
  end

  defp serialize(task) do
    %{
      id: task.id,
      name: task.name,
      prompt: task.prompt,
      repeat: to_string(task.repeat),
      schedule_time: task.schedule_time,
      every_n: task.every_n,
      enabled: task.enabled,
      next_run_at: Format.iso8601(task.next_run_at),
      last_run_at: Format.iso8601(task.last_run_at)
    }
  end
end
