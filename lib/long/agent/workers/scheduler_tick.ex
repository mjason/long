defmodule Long.Agent.Workers.SchedulerTick do
  @moduledoc """
  Cron tick (every minute). Drives BOTH periodic subsystems off one scan:

    * `Long.Agent.ScheduledTask` → enqueue `RunScheduledTask` (an LLM turn that
      always delivers) for each due row.
    * `Long.Agent.Monitor` → enqueue `RunMonitor` (a Deno script that decides
      whether to notify) for each due row.

  Both share `Schedule.classify/2` (fire / rearm / expire / wait) so a missed
  window self-heals identically. Mirrors `reflect/scheduler.py:check`.
  """

  use Oban.Worker, queue: :agent, max_attempts: 3

  require Logger

  alias Long.Agent
  alias Long.Agent.{Schedule, ScheduledTask, Workers.RunMonitor, Workers.RunScheduledTask}
  alias Long.Heartbeat

  @impl true
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    # page: false — scan ALL tasks. The `:read` action is keyset-paginated for
    # GraphQL; without this the scheduler would silently process only the first
    # page (25) if a pagination default ever flips, dropping tasks #26+ with no
    # error. The scheduler must always see the whole table.
    case Agent.list_scheduled_tasks(page: false) do
      {:ok, tasks} ->
        Enum.each(tasks, &handle(&1, now))
        scan_monitors(now)
        # Liveness heartbeat — recorded on EVERY completed tick, including ones
        # that fired nothing (the common case). Tracks execution, not insertion;
        # `SchedulerWatchdog` and `/healthz` read it. Never moved to the
        # {:error, _} path: a failed read should look stale so Oban retries.
        Heartbeat.beat(:scheduler)
        :ok

      {:error, e} ->
        {:error, e}
    end
  end

  # ── monitors (Long.Agent.Monitor) ────────────────────────────────────

  defp scan_monitors(now) do
    case Agent.list_monitors(page: false) do
      {:ok, monitors} -> Enum.each(monitors, &handle_monitor(&1, now))
      _ -> :ok
    end
  end

  defp handle_monitor(monitor, now) do
    case Schedule.classify(monitor_as_task(monitor), now) do
      :fire -> fire_monitor(monitor, now)
      :rearm -> rearm_monitor(monitor, now)
      :expire -> Agent.disable_monitor(monitor)
      :wait -> :ok
    end
  rescue
    e ->
      Logger.error("SchedulerTick: crash handling monitor #{monitor.id}: #{inspect(e)}")
      :ok
  end

  # `Schedule.classify`/`compute_next_run_at` pattern-match `%ScheduledTask{}`;
  # reuse them by projecting the monitor's scheduling fields into a transient one.
  defp monitor_as_task(m) do
    %ScheduledTask{
      repeat: m.repeat,
      schedule_time: m.schedule_time,
      every_n: m.every_n,
      next_run_at: m.next_run_at,
      max_delay_hours: m.max_delay_hours,
      enabled: m.enabled
    }
  end

  defp fire_monitor(monitor, now) do
    next = Schedule.compute_next_run_at(monitor_as_task(monitor), now)

    with {:ok, _job} <- Oban.insert(RunMonitor.new(%{monitor_id: monitor.id})),
         {:ok, _} <- Agent.record_monitor_run(monitor, %{next_run_at: next}) do
      if monitor.repeat == :once, do: Agent.disable_monitor(monitor)
      :ok
    else
      error ->
        Logger.warning("SchedulerTick: failed to fire monitor #{monitor.id}: #{inspect(error)}")
        :ok
    end
  end

  defp rearm_monitor(monitor, now) do
    next = Schedule.compute_next_run_at(monitor_as_task(monitor), now)
    _ = Agent.record_monitor_run(monitor, %{next_run_at: next})
    :ok
  end

  # Act on the pure `Schedule.classify/2` verdict. Each task is isolated in
  # its own try/rescue so one bad row can't abort the others due this tick.
  defp handle(task, now) do
    case Schedule.classify(task, now) do
      :fire -> fire(task, now)
      :rearm -> rearm(task, now)
      :expire -> expire(task)
      :wait -> :ok
    end
  rescue
    e ->
      Logger.error("SchedulerTick: crash handling task #{task.id}: #{inspect(e)}")
      :ok
  end

  # Enqueue the job FIRST, then advance next_run_at. If advancing fails under
  # SQLite write contention, the job is already queued (and RunScheduledTask's
  # `unique` dedups a re-enqueue next tick), so a run is never silently lost.
  defp fire(task, now) do
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
  end

  # A recurring task slipped past its catch-up window. Roll next_run_at forward
  # to the next future occurrence WITHOUT firing (no stale, wrong-time run) and
  # WITHOUT touching last_run_at (it didn't actually run). This is what stops a
  # missed window from wedging the task forever. Logged at warning so the next
  # such event is visible in minutes, not discovered days later.
  defp rearm(task, now) do
    next = Schedule.compute_next_run_at(task, now)

    case Agent.record_scheduled_run(task, %{next_run_at: next}) do
      {:ok, _} ->
        Logger.warning(
          "SchedulerTick: task #{task.id} (#{task.name}) missed its window " <>
            "(next_run_at=#{inspect(task.next_run_at)}, >#{task.max_delay_hours}h late); " <>
            "skipped the stale run, re-armed to #{inspect(next)}."
        )

        :ok

      error ->
        Logger.warning("SchedulerTick: failed to re-arm task #{task.id}: #{inspect(error)}")
        :ok
    end
  end

  # A one-shot task that slipped past its window can never fire on time again;
  # disable it so it stops being polled instead of lingering enabled-but-never-due.
  defp expire(task) do
    Logger.info(
      "SchedulerTick: one-shot task #{task.id} (#{task.name}) missed its window; disabling."
    )

    _ = Agent.disable_scheduled_task(task)
    :ok
  end
end
