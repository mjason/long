defmodule Long.Agent.ActivityTest do
  use ExUnit.Case, async: false

  import Long.AsyncHelpers, only: [eventually: 1]

  alias Long.Agent.Activity

  setup do
    sid = "test_session_#{System.unique_integer([:positive])}"
    on_exit(fn -> Activity.unregister(sid) end)
    %{sid: sid}
  end

  describe "register/1" do
    test "always succeeds, returns the inserted info", %{sid: sid} do
      assert {:ok, info} = Activity.register(sid)
      assert info.session_id == sid
      assert info.watcher_pid == self()
      assert is_integer(info.since)
    end

    test "two callers can both register against the same session", %{sid: sid} do
      this = self()

      first =
        spawn(fn ->
          {:ok, _} = Activity.register(sid)
          send(this, :registered_1)
          receive do: (:release -> :ok)
        end)

      second =
        spawn(fn ->
          {:ok, _} = Activity.register(sid)
          send(this, :registered_2)
          receive do: (:release -> :ok)
        end)

      assert_receive :registered_1, 500
      assert_receive :registered_2, 500

      pids = Activity.lookup(sid) |> Enum.map(& &1.watcher_pid) |> Enum.sort()
      assert Enum.sort([first, second]) == pids

      send(first, :release)
      send(second, :release)
    end

    test "different sessions stay isolated", %{sid: sid} do
      other = sid <> "_other"
      on_exit(fn -> Activity.unregister(other) end)

      assert {:ok, _} = Activity.register(sid)
      assert {:ok, _} = Activity.register(other)
      assert length(Activity.lookup(sid)) == 1
      assert length(Activity.lookup(other)) == 1
    end
  end

  describe "update/2" do
    test "merges fields into the caller's own entry", %{sid: sid} do
      {:ok, _} = Activity.register(sid)

      :ok = Activity.update(sid, %{turn: 3, tool: "web_scan"})

      assert [%{turn: 3, tool: "web_scan", watcher_pid: pid}] = Activity.lookup(sid)
      assert pid == self()
    end

    test "no-op on a session this process hasn't registered against", %{sid: sid} do
      assert :ok = Activity.update(sid, %{turn: 9})
      assert Activity.lookup(sid) == []
    end

    test "only updates the calling pid's row, not others", %{sid: sid} do
      this = self()

      other =
        spawn(fn ->
          {:ok, _} = Activity.register(sid)
          send(this, :ready)
          receive do: (:release -> :ok)
        end)

      assert_receive :ready, 500
      {:ok, _} = Activity.register(sid)

      :ok = Activity.update(sid, %{turn: 7})
      rows = Activity.lookup(sid)
      assert Enum.find(rows, &(&1.watcher_pid == self())).turn == 7
      assert Enum.find(rows, &(&1.watcher_pid == other)).turn == nil

      send(other, :release)
    end
  end

  describe "auto-cleanup on watcher death" do
    test "DOWN monitor removes the dead pid's row only", %{sid: sid} do
      this = self()
      {:ok, _} = Activity.register(sid)

      doomed =
        spawn(fn ->
          {:ok, _} = Activity.register(sid)
          send(this, :ready)
          receive do: (:stop -> :ok)
        end)

      assert_receive :ready, 500
      assert length(Activity.lookup(sid)) == 2

      ref = Process.monitor(doomed)
      send(doomed, :stop)
      assert_receive {:DOWN, ^ref, :process, ^doomed, _}, 500

      eventually(fn -> length(Activity.lookup(sid)) == 1 end)
      assert [%{watcher_pid: pid}] = Activity.lookup(sid)
      assert pid == self()
    end
  end

  describe "describe/1" do
    test "renders a status sentence with duration + turn + tool", %{sid: sid} do
      {:ok, _} = Activity.register(sid)
      :ok = Activity.update(sid, %{turn: 4, tool: "web_scan"})
      [info] = Activity.lookup(sid)

      text = Activity.describe(info)
      assert text =~ "运行中"
      assert text =~ "web_scan"
      assert text =~ "第 4 轮"
    end

    test "drops missing fields gracefully", %{sid: sid} do
      {:ok, _} = Activity.register(sid)
      [info] = Activity.lookup(sid)
      assert Activity.describe(info) =~ "运行中"
    end
  end

end
