defmodule Long.Agent.SchedulerWatchdog do
  @moduledoc """
  Functional-liveness watchdog for the per-minute scheduler.

  ## Why this exists

  The scheduler is driven by `Oban.Plugins.Cron`, a single GenServer whose only
  engine is a self-rescheduling `Process.send_after(self(), :evaluate, …)` loop.
  If that one timer cycle ever breaks — a WSL2 host suspend / monotonic-clock
  jump on resume, a dropped message, or `:evaluate` blocking inside a SQLite
  write — the cron loop stops inserting jobs while the **process stays alive**.
  Plain OTP supervision can't help: it only reacts to *exits*, and this is a
  hang, not a crash. That is exactly how the scheduler went silent for 5 days
  with no exception captured.

  This watchdog closes that blind spot. It is deliberately an **independent**
  process that does NOT share fate with the cron timer: it runs its own check
  loop and reads an in-VM heartbeat (`Long.Agent.SchedulerHeartbeat`), so a wedge
  *inside* Oban can't wedge the detector too.

  ## What it does

  Every `:check_ms` it reads the last tick time. If no tick has completed for
  longer than `:stale_ms`, it (1) screams — `:telemetry` + `ErrorTracker.report`,
  so a hang surfaces in `/errors` within minutes exactly as a crash would — and
  (2) recovers by restarting **just the Cron plugin** (Oban's own supervisor
  re-arms a fresh `:evaluate` timer); queues and in-flight jobs are untouched.

  Recovery is **debounced**: at most `:max_recoveries` within `:window_ms`, then
  it stops restarting and only keeps alerting. A scheduler you can *see* is
  wedged beats a kill-restart thrash you can't. Set `recover?: false` to alert
  without auto-restarting (useful to observe the alert before trusting the kill).

  All timings/behaviour are overridable via
  `config :long, Long.Agent.SchedulerWatchdog, …` and via `start_link/1` opts
  (the latter also exposes `:now_fun` / `:recover_fun` seams for tests).
  """

  use GenServer
  require Logger

  alias Long.Heartbeat

  # The `Long.Heartbeat` source the scheduler tick beats on.
  @source :scheduler

  @check_ms :timer.seconds(90)
  # 3 missed minute-ticks — clear of one slow tick, recovers in minutes not days.
  @stale_ms :timer.minutes(3)
  @max_recoveries 3
  @window_ms :timer.hours(1)

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    cfg = Application.get_env(:long, __MODULE__, [])
    get = fn key, default -> opts[key] || cfg[key] || default end

    state = %{
      check_ms: get.(:check_ms, @check_ms),
      stale_ms: get.(:stale_ms, @stale_ms),
      max_recoveries: get.(:max_recoveries, @max_recoveries),
      window_ms: get.(:window_ms, @window_ms),
      recover?: Keyword.get(opts, :recover?, Keyword.get(cfg, :recover?, true)),
      now_fun: Keyword.get(opts, :now_fun, fn -> System.monotonic_time(:millisecond) end),
      recover_fun: Keyword.get(opts, :recover_fun, &__MODULE__.restart_cron/0),
      recoveries: []
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_info(:check, state) do
    state =
      case Heartbeat.last_ms(@source) do
        # No tick has run since boot yet — nothing to judge. (The watchdog can
        # start before the first cron tick fires.)
        nil ->
          state

        last ->
          age = state.now_fun.() - last
          if age > state.stale_ms, do: alert_and_recover(state, age), else: state
      end

    {:noreply, schedule(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule(state) do
    Process.send_after(self(), :check, state.check_ms)
    state
  end

  defp alert_and_recover(state, age) do
    :telemetry.execute([:long, :scheduler, :watchdog, :stale], %{age_ms: age}, %{})
    now = state.now_fun.()
    recent = Enum.filter(state.recoveries, &(now - &1 < state.window_ms))

    cond do
      length(recent) >= state.max_recoveries ->
        # Persistent fault: stop restarting, keep screaming. A visible wedge is
        # safer than a restart storm masking a root cause (e.g. disk full).
        Logger.error(
          "SchedulerWatchdog: tick stale #{age}ms but recovery cap " <>
            "(#{state.max_recoveries}/#{div(state.window_ms, 60_000)}min) hit — ALERT ONLY"
        )

        report(age, "scheduler wedged, recovery cap hit")
        %{state | recoveries: recent}

      true ->
        Logger.error("SchedulerWatchdog: tick stale #{age}ms — restarting Cron plugin")
        report(age, "scheduler tick stale")
        if state.recover?, do: state.recover_fun.()
        %{state | recoveries: [now | recent]}
    end
  end

  # Alerting must NEVER crash the watchdog — a failed report can't be allowed to
  # take down the very thing watching the scheduler.
  defp report(age, message) do
    ErrorTracker.report(%RuntimeError{message: "#{message} (#{age}ms)"}, [], %{
      source: "scheduler_watchdog",
      age_ms: age
    })

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  Restart only the Oban Cron plugin so a fresh `:evaluate` timer is armed.
  Killing the plugin lets Oban's own one_for_one supervisor restart just that
  child — queues and in-flight jobs are left running (far lighter than bouncing
  the whole Oban tree). Defensive: tolerates Oban's internal registry key
  shifting across minor versions by degrading to a no-op rather than crashing
  the watchdog.
  """
  def restart_cron do
    pid = Oban.Registry.whereis(Oban, {:plugin, Oban.Plugins.Cron})
    if is_pid(pid), do: Process.exit(pid, :kill), else: :noop
  rescue
    e ->
      Logger.warning("SchedulerWatchdog: could not restart Cron plugin: #{inspect(e)}")
      :error
  end
end
