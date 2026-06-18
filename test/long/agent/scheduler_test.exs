defmodule Long.Agent.SchedulerTest do
  use Long.DataCase, async: false
  use Oban.Testing, repo: Long.Repo

  alias Long.Agent
  alias Long.Agent.{Memory, Schedule, ScheduledTask, SessionRunner}
  alias Long.Agent.Workers.{L4Archive, RunScheduledTask, SchedulerTick}

  describe "Schedule.compute_next_run_at/2" do
    test ":every_n_minutes adds the interval" do
      task = %ScheduledTask{repeat: :every_n_minutes, every_n: 15}
      now = ~U[2026-05-14 12:00:00Z]
      assert ~U[2026-05-14 12:15:00Z] == Schedule.compute_next_run_at(task, now)
    end

    test ":every_n_hours adds the interval" do
      task = %ScheduledTask{repeat: :every_n_hours, every_n: 3}
      now = ~U[2026-05-14 12:00:00Z]
      assert ~U[2026-05-14 15:00:00Z] == Schedule.compute_next_run_at(task, now)
    end

    test ":daily rolls to the next day if today's HH:MM is past" do
      task = %ScheduledTask{repeat: :daily, schedule_time: "08:00"}
      now = ~U[2026-05-14 09:00:00Z]
      assert ~U[2026-05-15 08:00:00Z] == Schedule.compute_next_run_at(task, now)
    end

    test ":daily lands on today if HH:MM is still upcoming" do
      task = %ScheduledTask{repeat: :daily, schedule_time: "23:00"}
      now = ~U[2026-05-14 08:00:00Z]
      assert ~U[2026-05-14 23:00:00Z] == Schedule.compute_next_run_at(task, now)
    end

    test ":weekday skips Saturday/Sunday" do
      task = %ScheduledTask{repeat: :weekday, schedule_time: "08:00"}
      friday_evening = ~U[2026-05-15 18:00:00Z]
      next = Schedule.compute_next_run_at(task, friday_evening)
      assert Date.day_of_week(DateTime.to_date(next)) in 1..5
    end

    test ":weekly adds 7 days" do
      task = %ScheduledTask{repeat: :weekly, schedule_time: "08:00"}
      now = ~U[2026-05-14 09:00:00Z]
      assert DateTime.diff(Schedule.compute_next_run_at(task, now), now) > 6 * 86_400
    end
  end

  describe "Schedule.due?/2" do
    test "disabled task is never due" do
      task = %ScheduledTask{enabled: false, next_run_at: ~U[2020-01-01 00:00:00Z]}
      refute Schedule.due?(task, DateTime.utc_now())
    end

    test "future next_run_at is not due" do
      task = %ScheduledTask{enabled: true, next_run_at: DateTime.add(DateTime.utc_now(), 3600)}
      refute Schedule.due?(task, DateTime.utc_now())
    end

    test "past next_run_at within delay window is due" do
      task = %ScheduledTask{
        enabled: true,
        next_run_at: DateTime.add(DateTime.utc_now(), -300),
        max_delay_hours: 6
      }

      assert Schedule.due?(task, DateTime.utc_now())
    end

    test "past next_run_at outside the delay window is skipped" do
      task = %ScheduledTask{
        enabled: true,
        next_run_at: DateTime.add(DateTime.utc_now(), -7 * 3600),
        max_delay_hours: 6
      }

      refute Schedule.due?(task, DateTime.utc_now())
    end
  end

  describe "Schedule timezone context (static note + per-turn now_line)" do
    test "timezone_note states the zone + store-UTC rule, with no clock" do
      note = Schedule.timezone_note()

      assert note =~ "Asia/Shanghai"
      assert note =~ "MUST be UTC"
      # No current time here — it must not bust the cached system prompt.
      refute note =~ "Current time"
    end

    test "now_line carries UTC + the user's local time for the current turn" do
      line = Schedule.now_line(~U[2026-06-11 23:00:00Z])

      assert line =~ "2026-06-11T23:00:00Z UTC"
      # 23:00Z + 8h = next-day 07:00 CST — proves the tz database is wired in.
      assert line =~ "2026-06-12 07:00"
      assert line =~ "Asia/Shanghai"
    end
  end

  describe "SchedulerTick worker" do
    setup do
      {:ok, sess} = Agent.start_session(%{title: "for-cron"})
      {:ok, sess: sess}
    end

    test "enqueues RunScheduledTask for due tasks and advances next_run_at",
         %{sess: sess} do
      past = DateTime.add(DateTime.utc_now(), -60)

      {:ok, task} =
        Agent.create_scheduled_task(%{
          name: "hourly-check",
          session_id: sess.id,
          prompt: "do your thing",
          repeat: :every_n_hours,
          every_n: 1,
          next_run_at: past
        })

      :ok = perform_job(SchedulerTick, %{})

      assert_enqueued(worker: RunScheduledTask, args: %{"task_id" => task.id})

      {:ok, updated} = Agent.get_scheduled_task(task.id)
      assert updated.last_run_at != nil
      assert DateTime.compare(updated.next_run_at, past) == :gt
    end

    test ":once tasks get disabled after firing", %{sess: sess} do
      {:ok, task} =
        Agent.create_scheduled_task(%{
          name: "one-shot",
          session_id: sess.id,
          prompt: "remind me",
          repeat: :once,
          next_run_at: DateTime.add(DateTime.utc_now(), -60)
        })

      :ok = perform_job(SchedulerTick, %{})

      {:ok, updated} = Agent.get_scheduled_task(task.id)
      refute updated.enabled
    end

    test "skips tasks whose next_run_at is in the future", %{sess: sess} do
      future = DateTime.add(DateTime.utc_now(), 3600)

      {:ok, _task} =
        Agent.create_scheduled_task(%{
          name: "later",
          session_id: sess.id,
          prompt: "wait",
          repeat: :every_n_hours,
          every_n: 1,
          next_run_at: future
        })

      :ok = perform_job(SchedulerTick, %{})

      refute_enqueued(worker: RunScheduledTask)
    end

    # Regression: a recurring task that missed its window by more than
    # max_delay_hours used to wedge forever — `due?` stayed false (stale) and
    # next_run_at was only advanced on the fire path, so it never recovered.
    # It must now re-arm to a future slot instead of firing a stale run.
    test "recurring task past the delay window is re-armed, not fired or wedged",
         %{sess: sess} do
      stale = DateTime.add(DateTime.utc_now(), -30 * 86_400)

      {:ok, task} =
        Agent.create_scheduled_task(%{
          name: "wedged-daily",
          session_id: sess.id,
          prompt: "fill worklog",
          repeat: :daily,
          schedule_time: "10:00",
          max_delay_hours: 6,
          next_run_at: stale
        })

      :ok = perform_job(SchedulerTick, %{})

      # Did NOT fire a stale run...
      refute_enqueued(worker: RunScheduledTask)

      {:ok, updated} = Agent.get_scheduled_task(task.id)
      # ...still enabled, last_run_at untouched (it didn't actually run)...
      assert updated.enabled
      assert updated.last_run_at == nil
      # ...and next_run_at rolled forward to a future slot (self-healed).
      assert DateTime.compare(updated.next_run_at, DateTime.utc_now()) == :gt
    end

    test "one-shot task past the delay window is disabled, not fired", %{sess: sess} do
      stale = DateTime.add(DateTime.utc_now(), -7 * 3600)

      {:ok, task} =
        Agent.create_scheduled_task(%{
          name: "missed-one-shot",
          session_id: sess.id,
          prompt: "too late now",
          repeat: :once,
          max_delay_hours: 6,
          next_run_at: stale
        })

      :ok = perform_job(SchedulerTick, %{})

      refute_enqueued(worker: RunScheduledTask)

      {:ok, updated} = Agent.get_scheduled_task(task.id)
      refute updated.enabled
    end
  end

  describe "list_scheduled_tasks pagination" do
    test "page: false returns ALL tasks, not a capped first page" do
      {:ok, sess} = Agent.start_session(%{title: "bulk"})

      for i <- 1..30 do
        {:ok, _} =
          Agent.create_scheduled_task(%{
            name: "bulk-#{i}-#{System.unique_integer([:positive])}",
            session_id: sess.id,
            prompt: "x",
            repeat: :daily,
            next_run_at: DateTime.utc_now()
          })
      end

      # The :read action is keyset-paginated (default_limit 25) for GraphQL;
      # the scheduler must see the whole table, so it passes page: false.
      assert {:ok, tasks} = Agent.list_scheduled_tasks(page: false)
      assert is_list(tasks)
      assert length(tasks) >= 30
    end
  end

  describe "RunScheduledTask worker" do
    test "delegates to SessionRunner.send_user_message" do
      {:ok, sess} = Agent.start_session(%{title: "scheduled-target"})
      :ok = SessionRunner.subscribe(sess.id)

      {:ok, task} =
        Agent.create_scheduled_task(%{
          name: "delegating",
          session_id: sess.id,
          prompt: "hello from cron",
          repeat: :every_n_minutes,
          every_n: 5
        })

      :ok = perform_job(RunScheduledTask, %{"task_id" => task.id})

      assert_receive {:message_persisted, %{message: %{role: :user, content: "hello from cron"}}},
                     1_000

      assert_receive :loop_ended, 2_000
    end
  end

  describe "L4Archive worker" do
    setup do
      Application.put_env(:long, Long.Agent,
        memory_root: Path.expand("priv/agent/memory", File.cwd!()),
        temp_root: Path.expand("priv/agent/temp", File.cwd!()),
        archive: [idle_hours: 0]
      )

      on_exit(fn -> Application.delete_env(:long, Long.Agent) end)
      :ok
    end

    test "archives sessions that have messages and no existing archive" do
      {:ok, sess} = Agent.start_session(%{title: "to-archive"})

      {:ok, _} =
        Agent.append_message(%{session_id: sess.id, role: :user, content: "hi", turn: 1})

      {:ok, _} =
        Agent.append_message(%{session_id: sess.id, role: :assistant, content: "hello", turn: 1})

      assert :ok = perform_job(L4Archive, %{})

      assert {:ok, [archive]} = Agent.list_archives()
      assert archive.original_session_id == sess.id

      {:ok, refetched} = Agent.get_session(sess.id)
      assert refetched.status == :archived
    end

    test "skips empty sessions" do
      {:ok, _sess} = Agent.start_session(%{title: "empty"})
      assert :ok = perform_job(L4Archive, %{})
      assert {:ok, []} = Agent.list_archives()
    end

    test "does not double-archive" do
      {:ok, sess} = Agent.start_session(%{title: "no-double"})

      {:ok, _} =
        Agent.append_message(%{session_id: sess.id, role: :user, content: "hi", turn: 1})

      {:ok, _archive} = Memory.archive_session(sess.id)

      assert :ok = perform_job(L4Archive, %{})
      assert {:ok, archives} = Agent.list_archives()
      assert length(archives) == 1
    end
  end
end
