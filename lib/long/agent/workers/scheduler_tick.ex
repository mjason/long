defmodule Long.Agent.Workers.SchedulerTick do
  @moduledoc """
  Cron tick (every minute). Lists every enabled `Long.Agent.ScheduledTask`,
  marks the due ones as run, and enqueues a `RunScheduledTask` job for each.
  Mirrors the polling behaviour of `reflect/scheduler.py:check`.
  """

  use Oban.Worker, queue: :agent, max_attempts: 3

  alias Long.Agent
  alias Long.Agent.{Schedule, Workers.RunScheduledTask}

  @impl true
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    case Agent.list_scheduled_tasks() do
      {:ok, tasks} ->
        tasks
        |> Enum.filter(&Schedule.due?(&1, now))
        |> Enum.each(&handle_due(&1, now))

        :ok

      {:error, e} ->
        {:error, e}
    end
  end

  defp handle_due(task, now) do
    next = Schedule.compute_next_run_at(task, now)

    {:ok, _updated} =
      Agent.record_scheduled_run(task, %{last_run_at: now, next_run_at: next})

    {:ok, _job} =
      %{task_id: task.id}
      |> RunScheduledTask.new()
      |> Oban.insert()

    if task.repeat == :once do
      {:ok, _} = Agent.disable_scheduled_task(task)
    end
  end
end
