defmodule Long.Jido.SchedulingToolsTest do
  use Long.DataCase, async: false

  alias Long.Agent
  alias Long.Jido.Tools.{CancelScheduledTask, ListScheduledTasks, ScheduleTask}

  setup do
    {:ok, sess} = Agent.start_session(%{title: "for-scheduling"})
    {:ok, sess: sess, ctx: %{session_id: sess.id}}
  end

  describe "ScheduleTask" do
    test "creates a daily recurring task", %{sess: sess, ctx: ctx} do
      assert {:ok, %{status: "success", id: id, name: "daily_brief", next_run_at: nra}} =
               Jido.Exec.run(
                 ScheduleTask,
                 %{
                   name: "daily_brief",
                   prompt: "summarize the day",
                   repeat: "daily",
                   at: "00:00"
                 },
                 ctx
               )

      assert is_binary(nra)
      {:ok, task} = Agent.get_scheduled_task(id)
      assert task.repeat == :daily
      assert task.session_id == sess.id
      assert task.enabled
    end

    test "creates a one-shot task with explicit next_run_at", %{ctx: ctx} do
      future = "2099-12-31T00:00:00Z"

      assert {:ok, %{status: "success", repeat: "once", next_run_at: ^future}} =
               Jido.Exec.run(
                 ScheduleTask,
                 %{
                   name: "once_task",
                   prompt: "ping",
                   repeat: "once",
                   next_run_at: future
                 },
                 ctx
               )
    end

    test "rejects unknown repeat", %{ctx: ctx} do
      assert {:ok, %{status: "error", msg: msg}} =
               Jido.Exec.run(
                 ScheduleTask,
                 %{name: "x", prompt: "y", repeat: "fortnightly"},
                 ctx
               )

      assert msg =~ "invalid repeat"
    end

    test "rejects empty name", %{ctx: ctx} do
      assert {:ok, %{status: "error", msg: msg}} =
               Jido.Exec.run(ScheduleTask, %{name: "", prompt: "y"}, ctx)

      assert msg =~ "name"
    end

    test "rejects empty prompt", %{ctx: ctx} do
      assert {:ok, %{status: "error", msg: msg}} =
               Jido.Exec.run(ScheduleTask, %{name: "x", prompt: ""}, ctx)

      assert msg =~ "prompt"
    end

    test "fails without session_id in ctx" do
      assert {:ok, %{status: "error", msg: msg}} =
               Jido.Exec.run(ScheduleTask, %{name: "x", prompt: "y"}, %{})

      assert msg =~ "session"
    end
  end

  describe "ListScheduledTasks" do
    test "lists only the current session's tasks", %{sess: sess, ctx: ctx} do
      {:ok, _} = Agent.create_scheduled_task(scheduled_attrs(sess.id, "mine"))

      {:ok, other_sess} = Agent.start_session(%{title: "other"})
      {:ok, _} = Agent.create_scheduled_task(scheduled_attrs(other_sess.id, "not_mine"))

      assert {:ok, %{count: 1, tasks: [%{name: "mine"}]}} =
               Jido.Exec.run(ListScheduledTasks, %{}, ctx)
    end
  end

  describe "CancelScheduledTask" do
    test "destroys by default", %{sess: sess, ctx: ctx} do
      {:ok, task} = Agent.create_scheduled_task(scheduled_attrs(sess.id, "kill_me"))

      assert {:ok, %{status: "success", action: "destroyed"}} =
               Jido.Exec.run(CancelScheduledTask, %{name: "kill_me"}, ctx)

      assert {:error, _} = Agent.get_scheduled_task(task.id)
    end

    test "permanent=false only disables", %{sess: sess, ctx: ctx} do
      {:ok, task} = Agent.create_scheduled_task(scheduled_attrs(sess.id, "pause_me"))

      assert {:ok, %{status: "success", action: "disabled"}} =
               Jido.Exec.run(CancelScheduledTask, %{name: "pause_me", permanent: false}, ctx)

      {:ok, after_disable} = Agent.get_scheduled_task(task.id)
      refute after_disable.enabled
    end

    test "returns error when task not found", %{ctx: ctx} do
      assert {:ok, %{status: "error", msg: msg}} =
               Jido.Exec.run(CancelScheduledTask, %{name: "ghost"}, ctx)

      assert msg =~ "no scheduled task"
    end
  end

  defp scheduled_attrs(session_id, name) do
    %{
      name: name,
      session_id: session_id,
      prompt: "x",
      repeat: :daily,
      schedule_time: "00:00",
      next_run_at: DateTime.add(DateTime.utc_now(), 3600)
    }
  end
end
