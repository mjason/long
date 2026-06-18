defmodule Long.Agent.ActivityTest do
  use ExUnit.Case, async: false

  import Long.AsyncHelpers, only: [eventually: 1]

  alias Long.Agent.Activity

  setup do
    sid = "test_session_#{System.unique_integer([:positive])}"
    on_exit(fn -> Activity.release(sid) end)
    %{sid: sid}
  end

  describe "try_acquire_or_enqueue/2" do
    test "first caller acquires the slot", %{sid: sid} do
      assert :acquired = Activity.try_acquire_or_enqueue(sid, :payload)
      assert %{watcher_pid: pid} = Activity.lookup(sid)
      assert pid == self()
    end

    test "second caller enqueues; FIFO order preserved on dequeue", %{sid: sid} do
      this = self()

      owner =
        spawn(fn ->
          :acquired = Activity.try_acquire_or_enqueue(sid, :first_payload)
          send(this, :acquired)
          receive do: (:release -> Activity.release(sid))
        end)

      assert_receive :acquired, 500

      assert :enqueued = Activity.try_acquire_or_enqueue(sid, :payload_a)
      assert :enqueued = Activity.try_acquire_or_enqueue(sid, :payload_b)

      assert :payload_a = Activity.dequeue(sid)
      assert :payload_b = Activity.dequeue(sid)
      assert nil == Activity.dequeue(sid)

      send(owner, :release)
    end

    test "different sessions stay isolated", %{sid: sid} do
      other = sid <> "_other"
      on_exit(fn -> Activity.release(other) end)

      assert :acquired = Activity.try_acquire_or_enqueue(sid, :p1)
      assert :acquired = Activity.try_acquire_or_enqueue(other, :p2)
    end
  end

  describe "release/1" do
    test "frees the slot for the next acquirer", %{sid: sid} do
      :acquired = Activity.try_acquire_or_enqueue(sid, :p)
      Activity.release(sid)
      eventually(fn -> Activity.lookup(sid) == nil end)
      assert :acquired = Activity.try_acquire_or_enqueue(sid, :p2)
    end

    test "DOWN auto-cleans when owner dies without releasing", %{sid: sid} do
      this = self()

      doomed =
        spawn(fn ->
          :acquired = Activity.try_acquire_or_enqueue(sid, :p)
          send(this, :ready)
          receive do: (:stop -> :ok)
        end)

      assert_receive :ready, 500
      assert %{watcher_pid: ^doomed} = Activity.lookup(sid)

      ref = Process.monitor(doomed)
      send(doomed, :stop)
      assert_receive {:DOWN, ^ref, :process, ^doomed, _}, 500

      eventually(fn -> Activity.lookup(sid) == nil end)
    end
  end

  describe "update/2" do
    test "merges fields into the owner's row", %{sid: sid} do
      :acquired = Activity.try_acquire_or_enqueue(sid, :p)
      Activity.update(sid, %{turn: 3, tool: "web_scan"})
      assert %{turn: 3, tool: "web_scan"} = Activity.lookup(sid)
    end

    test "no-op when caller doesn't own the slot", %{sid: sid} do
      :ok = Activity.update(sid, %{turn: 9})
      assert Activity.lookup(sid) == nil
    end
  end

  describe "clear/1" do
    test "wipes owner + queue + btws atomically, returns prior owner pid", %{sid: sid} do
      :acquired = Activity.try_acquire_or_enqueue(sid, :owned)
      :enqueued = Activity.try_acquire_or_enqueue(sid, :q1)
      :ok = Activity.add_btw(sid, "note 1")

      assert Activity.lookup(sid) != nil

      assert {prior_pid, :ok} = Activity.clear(sid)
      assert prior_pid == self()

      assert Activity.lookup(sid) == nil
      assert nil == Activity.dequeue(sid)
      assert [] == Activity.take_btws(sid)
    end

    test "no-op on a session that was never touched, owner pid nil", %{sid: sid} do
      assert {nil, :ok} = Activity.clear(sid)
    end
  end

  describe "btw notes" do
    test "add_btw + take_btws round-trip, FIFO", %{sid: sid} do
      :acquired = Activity.try_acquire_or_enqueue(sid, :p)
      :ok = Activity.add_btw(sid, "PG-13 only")
      :ok = Activity.add_btw(sid, "also include 1990s posters")

      assert ["PG-13 only", "also include 1990s posters"] = Activity.take_btws(sid)
      assert [] = Activity.take_btws(sid)
    end

    test "take_btws empty for sessions with no notes", %{sid: sid} do
      assert [] = Activity.take_btws(sid)
    end
  end

  describe "describe/1" do
    test "without request, falls back to runtime + turn + tool", %{sid: sid} do
      :acquired = Activity.try_acquire_or_enqueue(sid, :p)
      Activity.update(sid, %{turn: 4, tool: "web_scan"})
      info = Activity.lookup(sid)

      text = Activity.describe(info)
      assert text =~ "running"
      assert text =~ "turn 4"
      assert text =~ "web_scan"
    end

    test "with request, leads with the user prompt preview", %{sid: sid} do
      :acquired = Activity.try_acquire_or_enqueue(sid, :p)
      Activity.update(sid, %{request: "帮我找雷欧奥特曼的图片", turn: 2, tool: "web_search"})

      text = Activity.describe(Activity.lookup(sid))
      assert text =~ "on “帮我找雷欧奥特曼的图片”"
      assert text =~ "running"
      assert text =~ "turn 2"
      assert text =~ "web_search"
    end
  end

  describe "ETS table survival across an Activity crash" do
    test "tables are owned by the Tables keeper, not Activity, so they outlive its crash" do
      keeper = Process.whereis(Long.Agent.Activity.Tables)
      assert is_pid(keeper)
      # Owner is the keeper, so an Activity crash leaves the tables (and every
      # in-flight session's slot) intact.
      assert :ets.info(Long.Agent.Activity.Owners, :owner) == keeper
      refute :ets.info(Long.Agent.Activity.Owners, :owner) == Process.whereis(Activity)
    end

    test "remonitor_survivors re-monitors live owners and drops dead ones" do
      # Isolated throwaway owners table — does NOT touch the global Activity, so
      # this can't race with concurrent tests.
      owners = :ets.new(:test_owners, [:set, :public])
      live = spawn(fn -> Process.sleep(:infinity) end)
      dead = spawn(fn -> :ok end)
      eventually(fn -> not Process.alive?(dead) end)

      row = fn pid -> %{watcher_pid: pid, watcher_ref: make_ref(), since: 0, turn: nil, tool: nil, request: nil} end
      :ets.insert(owners, {"live", row.(live)})
      :ets.insert(owners, {"dead", row.(dead)})

      monitors = Activity.remonitor_survivors(owners)

      # Dead watcher's slot freed (no DOWN would ever come for it otherwise).
      assert :ets.lookup(owners, "dead") == []
      # Live watcher kept, with a FRESH monitor ref tracked in the returned map.
      assert [{"live", %{watcher_pid: ^live, watcher_ref: ref}}] = :ets.lookup(owners, "live")
      assert monitors[ref] == {"live", live}

      Process.exit(live, :kill)
    end
  end
end
