defmodule Long.Agent.Workers.SchedulerTick do
  @moduledoc """
  Cron tick (every minute). Lists every enabled `Long.Agent.ScheduledTask`,
  marks the due ones as run, and enqueues a `RunScheduledTask` job for each.
  Mirrors the polling behaviour of `reflect/scheduler.py:check`.
  """

  use Oban.Worker, queue: :agent, max_attempts: 3

  require Logger

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

  # Enqueue the job FIRST, then advance next_run_at. If advancing fails
  # under SQLite write contention, the job is already queued (and
  # RunScheduledTask's `unique` dedups a re-enqueue next tick), so a run is
  # never silently lost. Each task is isolated so one failure can't abort
  # the others due this tick.
  defp handle_due(task, now) do
    next = Schedule.compute_next_run_at(task, now)

    with {:ok, _job} <- Oban.insert(RunScheduledTask.new(%{task_id: task.id})),
         {:ok, _updated} <-
           Agent.record_scheduled_run(task, %{last_run_at: now, next_run_at: next}) do
      if task.repeat == :once, do: Agent.disable_scheduled_task(task)
      :ok
    else
      error ->
        Logger.warning("SchedulerTick: failed to fire task #{task.id}: #{inspect(error)}")
        :ok
    end
  rescue
    e ->
      Logger.error("SchedulerTick: crash firing task #{task.id}: #{inspect(e)}")
      :ok
  end
end
