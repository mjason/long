defmodule Long.Agent.SchedulerWatchdogTest do
  # async: false — the heartbeat lives in a global ETS table.
  use ExUnit.Case, async: false

  alias Long.Agent.SchedulerWatchdog
  alias Long.Heartbeat

  setup do
    Heartbeat.beat(:scheduler)
    # Drive `age` deterministically off the recorded value instead of the wall
    # clock: now_fun = base + offset ⇒ age == offset, regardless of real time.
    base = Heartbeat.last_ms(:scheduler)
    {:ok, base: base}
  end

  # Big check_ms so the watchdog's own timer never fires mid-test; we drive
  # :check by hand. recover_fun pings the test instead of killing the real cron.
  defp start_wd(opts) do
    test = self()

    defaults = [
      name: :"wd_#{System.unique_integer([:positive])}",
      check_ms: 60_000,
      stale_ms: 1_000,
      recover_fun: fn -> send(test, :recovered) end
    ]

    {:ok, pid} = SchedulerWatchdog.start_link(Keyword.merge(defaults, opts))
    pid
  end

  defp attach_stale_telemetry do
    test = self()
    ref = "wd-tel-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      ref,
      [:long, :scheduler, :watchdog, :stale],
      fn name, meas, _meta, _ -> send(test, {:telemetry, name, meas}) end,
      nil
    )

    ref
  end

  test "recovers + alerts when the heartbeat is stale beyond the threshold", %{base: base} do
    ref = attach_stale_telemetry()
    pid = start_wd(now_fun: fn -> base + 5_000 end)

    send(pid, :check)

    assert_receive :recovered, 500
    assert_receive {:telemetry, [:long, :scheduler, :watchdog, :stale], %{age_ms: 5_000}}, 500
    :telemetry.detach(ref)
  end

  test "does not recover when the heartbeat is fresh", %{base: base} do
    pid = start_wd(now_fun: fn -> base + 100 end)
    send(pid, :check)
    refute_receive :recovered, 300
  end

  test "ignores a missing heartbeat (no tick has run yet)" do
    :ets.delete(Heartbeat, :scheduler)
    pid = start_wd(now_fun: fn -> 999_999 end)
    send(pid, :check)
    refute_receive :recovered, 300
  end

  test "debounces: stops restarting after the cap, keeps the alert", %{base: base} do
    ref = attach_stale_telemetry()
    pid = start_wd(now_fun: fn -> base + 5_000 end, max_recoveries: 2, window_ms: 60_000)

    send(pid, :check)
    send(pid, :check)
    assert_receive :recovered, 500
    assert_receive :recovered, 500

    # Over the cap now → it must still alert but NOT restart again.
    send(pid, :check)
    assert_receive {:telemetry, [:long, :scheduler, :watchdog, :stale], _}, 500
    refute_receive :recovered, 300
    :telemetry.detach(ref)
  end

  test "recover?: false alerts but never restarts", %{base: base} do
    ref = attach_stale_telemetry()
    pid = start_wd(now_fun: fn -> base + 5_000 end, recover?: false)

    send(pid, :check)

    assert_receive {:telemetry, [:long, :scheduler, :watchdog, :stale], _}, 500
    refute_receive :recovered, 300
    :telemetry.detach(ref)
  end

  describe "Long.Heartbeat" do
    test "beat advances last_ms; reads back recent; age_ms is nil for unknown source" do
      Heartbeat.beat(:scheduler)
      last = Heartbeat.last_ms(:scheduler)
      assert is_integer(last)
      assert System.monotonic_time(:millisecond) - last < 1_000
      assert Heartbeat.age_ms(:never_beaten_source) == nil
    end
  end
end
