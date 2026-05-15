defmodule Long.Agent.Browser.Cli.LimiterTest do
  use ExUnit.Case, async: false

  alias Long.Agent.Browser.Cli.Limiter

  setup do
    # Each test gets a private Limiter with a tight `max` so we can
    # observe the queue mechanics without racing the application-wide
    # singleton.
    name = :"limiter_#{:rand.uniform(1_000_000_000)}"
    {:ok, pid} = Limiter.start_link(name: name, max: 2)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{name: name, pid: pid}
  end

  describe "acquire/release" do
    test "max concurrent holders are admitted immediately", %{name: name} do
      assert :ok = Limiter.acquire(name)
      assert :ok = Limiter.acquire(name)
      assert %{in_use: 2, waiting: 0, max: 2} = Limiter.stats(name)
    end

    test "third acquire blocks until a holder releases", %{name: name} do
      :ok = Limiter.acquire(name)
      :ok = Limiter.acquire(name)

      this = self()

      _waiter =
        spawn(fn ->
          :ok = Limiter.acquire(name, 5_000)
          send(this, :got_slot)
        end)

      # The waiter is queued, not yet served.
      refute_receive :got_slot, 100
      assert %{in_use: 2, waiting: 1} = Limiter.stats(name)

      :ok = Limiter.release(name)
      assert_receive :got_slot, 500
    end

    test "with_slot/2 always releases, even on exception", %{name: name} do
      :ok = Limiter.acquire(name)

      assert_raise RuntimeError, "boom", fn ->
        Limiter.with_slot(name, fn -> raise "boom" end)
      end

      # Only the manual acquire above is still held.
      eventually(fn -> Limiter.stats(name).in_use == 1 end)
    end

    test "holder process dying releases its slot automatically", %{name: name} do
      :ok = Limiter.acquire(name)

      pid =
        spawn(fn ->
          :ok = Limiter.acquire(name)
          # Sit on the slot, then exit normally — limiter must reap it.
          Process.sleep(50)
        end)

      # Briefly both slots are held.
      eventually(fn -> Limiter.stats(name).in_use == 2 end)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500

      # After the holder exits, in_use drops back to 1.
      eventually(fn -> Limiter.stats(name).in_use == 1 end)
    end
  end

  defp eventually(fun, attempts \\ 20, sleep_ms \\ 25) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(sleep_ms)
        {:cont, false}
      end
    end)
    |> case do
      true -> :ok
      false -> flunk("eventually/1 condition never became true")
    end
  end
end
