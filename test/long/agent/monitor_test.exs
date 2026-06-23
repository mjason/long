defmodule Long.Agent.MonitorTest do
  use Long.DataCase, async: false
  use Oban.Testing, repo: Long.Repo

  alias Long.Agent
  alias Long.Agent.Workers.{RunMonitor, SchedulerTick}

  setup do
    {:ok, sess} = Agent.start_session(%{title: "monitor-host"})
    {:ok, sess: sess}
  end

  describe "SchedulerTick drives monitors (reusing Schedule.classify)" do
    test "enqueues RunMonitor for a due monitor and advances next_run_at", %{sess: sess} do
      past = DateTime.add(DateTime.utc_now(), -60)

      {:ok, m} =
        Agent.create_monitor(%{
          name: "due-mon",
          session_id: sess.id,
          script: "console.log(JSON.stringify({notify:false}))",
          repeat: :every_n_minutes,
          every_n: 5,
          next_run_at: past
        })

      :ok = perform_job(SchedulerTick, %{})

      assert_enqueued(worker: RunMonitor, args: %{"monitor_id" => m.id})

      {:ok, updated} = Agent.get_monitor(m.id)
      assert DateTime.compare(updated.next_run_at, past) == :gt
    end

    test "re-arms (does not fire) a monitor that missed its window", %{sess: sess} do
      stale = DateTime.add(DateTime.utc_now(), -30 * 86_400)

      {:ok, m} =
        Agent.create_monitor(%{
          name: "stale-mon",
          session_id: sess.id,
          script: "console.log(JSON.stringify({notify:false}))",
          repeat: :every_n_minutes,
          every_n: 5,
          max_delay_hours: 6,
          next_run_at: stale
        })

      :ok = perform_job(SchedulerTick, %{})

      refute_enqueued(worker: RunMonitor)
      {:ok, updated} = Agent.get_monitor(m.id)
      assert DateTime.compare(updated.next_run_at, DateTime.utc_now()) == :gt
    end

    test "skips monitors whose next_run_at is in the future", %{sess: sess} do
      {:ok, _m} =
        Agent.create_monitor(%{
          name: "future-mon",
          session_id: sess.id,
          script: "console.log(JSON.stringify({notify:false}))",
          repeat: :every_n_minutes,
          every_n: 5,
          next_run_at: DateTime.add(DateTime.utc_now(), 3600)
        })

      :ok = perform_job(SchedulerTick, %{})
      refute_enqueued(worker: RunMonitor)
    end
  end

  # These actually execute Deno; tagged so they can be excluded where Deno isn't available.
  describe "RunMonitor decision + dedup" do
    @describetag :deno_exec

    test "notify:false → silent, nothing pushed", %{sess: sess} do
      {:ok, m} =
        Agent.create_monitor(%{
          name: "silent-mon",
          session_id: sess.id,
          script: "console.log('some debug'); console.log(JSON.stringify({notify:false}))",
          repeat: :every_n_minutes,
          every_n: 5
        })

      :ok = perform_job(RunMonitor, %{"monitor_id" => m.id})

      {:ok, updated} = Agent.get_monitor(m.id)
      assert updated.last_status == "silent"
      assert updated.last_run_at != nil
    end

    test "unparseable output → error", %{sess: sess} do
      {:ok, m} =
        Agent.create_monitor(%{
          name: "bad-mon",
          session_id: sess.id,
          script: "console.log('definitely not json')",
          repeat: :every_n_minutes,
          every_n: 5
        })

      :ok = perform_job(RunMonitor, %{"monitor_id" => m.id})

      {:ok, updated} = Agent.get_monitor(m.id)
      assert updated.last_status == "error"
    end

    test "notify:true with no bot binding records an error (nowhere to deliver)", %{sess: sess} do
      {:ok, m} =
        Agent.create_monitor(%{
          name: "notify-mon",
          session_id: sess.id,
          script: ~s|console.log(JSON.stringify({notify:true, message:"alert!"}))|,
          repeat: :every_n_minutes,
          every_n: 5
        })

      :ok = perform_job(RunMonitor, %{"monitor_id" => m.id})

      {:ok, updated} = Agent.get_monitor(m.id)
      # The web session has no bot_user, so the push target is missing.
      assert updated.last_status == "error"
      assert updated.last_output["decision"] == "notified"
    end

    test "notable runs are recorded in history; silent ticks are not", %{sess: sess} do
      {:ok, silent} =
        Agent.create_monitor(%{
          name: "hist-silent",
          session_id: sess.id,
          script: "console.log(JSON.stringify({notify:false}))",
          repeat: :every_n_minutes,
          every_n: 5
        })

      :ok = perform_job(RunMonitor, %{"monitor_id" => silent.id})
      assert monitor_runs(silent.id) == []

      {:ok, noisy} =
        Agent.create_monitor(%{
          name: "hist-noisy",
          session_id: sess.id,
          script: ~s|console.log(JSON.stringify({notify:true, message:"hi"}))|,
          repeat: :every_n_minutes,
          every_n: 5
        })

      :ok = perform_job(RunMonitor, %{"monitor_id" => noisy.id})
      :ok = perform_job(RunMonitor, %{"monitor_id" => noisy.id})

      runs = monitor_runs(noisy.id)
      assert length(runs) == 2
      assert Enum.all?(runs, &(&1.decision == "notified"))
      assert hd(runs).message == "hi"
    end
  end

  defp monitor_runs(id) do
    case Agent.list_monitor_runs(id, page: [limit: 100]) do
      {:ok, %{results: rows}} -> rows
      {:ok, rows} when is_list(rows) -> rows
      _ -> []
    end
  end
end
