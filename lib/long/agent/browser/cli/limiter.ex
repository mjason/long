defmodule Long.Agent.Browser.Cli.Limiter do
  @moduledoc """
  Token-bucket semaphore bounding concurrent `obscura fetch` subprocess
  spawns.

  Each Obscura process boots a real Chromium-based browser and uses
  200–400 MB of resident memory. On WSL2 / smaller dev machines, four
  in-flight at once will OOM or trigger swap. Cap concurrency to two
  by default — `Loop`'s parallel `dispatch_tools` will still feed jobs
  in batches, but only `:max` of them run at any moment.

  API:

      Limiter.acquire()  # blocks until a slot is free
      ... do work ...
      Limiter.release()

  Or use `Limiter.with_slot/1`, which handles acquire/release around a
  function and always releases on exception.

  Slot accounting tracks `{ref, count}` per holder pid: the same
  process can acquire multiple slots (each release pops one). When a
  holder process dies before releasing, the monitor reaps every slot
  it was holding in one go.
  """

  use GenServer

  @default_max 2
  @default_timeout 60_000

  # ── Public API ───────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Acquire a slot. Blocks the caller until one is available. The slot
  is automatically released when the caller process dies.
  """
  def acquire(name \\ __MODULE__, timeout \\ @default_timeout) do
    GenServer.call(name, :acquire, timeout)
  end

  @doc "Release one previously-acquired slot held by this process."
  def release(name \\ __MODULE__) do
    GenServer.cast(name, {:release, self()})
  end

  @doc """
  Run `fun` while holding a slot. Always releases, even on exception
  or process exit.
  """
  def with_slot(name \\ __MODULE__, fun) when is_function(fun, 0) do
    case acquire(name) do
      :ok ->
        try do
          fun.()
        after
          release(name)
        end

      {:error, _} = err ->
        err
    end
  end

  @doc "Inspect current state (debug/test only)."
  def stats(name \\ __MODULE__), do: GenServer.call(name, :stats)

  # ── GenServer ────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    max = Keyword.get(opts, :max, max_from_config())
    {:ok, %{max: max, in_use: 0, holders: %{}, waiters: :queue.new()}}
  end

  defp max_from_config do
    case Application.get_env(:long, Long.Agent.Browser, []) do
      cfg when is_list(cfg) ->
        Keyword.get(cfg, :cli_max_concurrent, @default_max)

      _ ->
        @default_max
    end
  end

  @impl true
  def handle_call(:acquire, {pid, _tag} = from, state) do
    if state.in_use < state.max do
      {:reply, :ok, grant(state, pid)}
    else
      {:noreply, %{state | waiters: :queue.in(from, state.waiters)}}
    end
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{max: state.max, in_use: state.in_use, waiting: :queue.len(state.waiters)},
     state}
  end

  @impl true
  def handle_cast({:release, pid}, state) do
    {:noreply, drop_one(state, pid) |> promote_next_waiter()}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.holders, pid) do
      {^ref, count} ->
        state = %{
          state
          | in_use: state.in_use - count,
            holders: Map.delete(state.holders, pid)
        }

        {:noreply, promote_next_waiter(state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── helpers ──────────────────────────────────────────────────────────

  defp grant(state, pid) do
    holders =
      case Map.get(state.holders, pid) do
        nil ->
          ref = Process.monitor(pid)
          Map.put(state.holders, pid, {ref, 1})

        {ref, count} ->
          Map.put(state.holders, pid, {ref, count + 1})
      end

    %{state | in_use: state.in_use + 1, holders: holders}
  end

  defp drop_one(state, pid) do
    case Map.get(state.holders, pid) do
      nil ->
        state

      {ref, 1} ->
        _ = Process.demonitor(ref, [:flush])
        %{state | in_use: state.in_use - 1, holders: Map.delete(state.holders, pid)}

      {ref, count} ->
        %{state | in_use: state.in_use - 1, holders: Map.put(state.holders, pid, {ref, count - 1})}
    end
  end

  defp promote_next_waiter(%{in_use: u, max: m} = state) when u >= m, do: state

  defp promote_next_waiter(state) do
    case :queue.out(state.waiters) do
      {:empty, _} ->
        state

      {{:value, {pid, _tag} = from}, rest} ->
        if Process.alive?(pid) do
          new_state = grant(%{state | waiters: rest}, pid)
          GenServer.reply(from, :ok)
          promote_next_waiter(new_state)
        else
          promote_next_waiter(%{state | waiters: rest})
        end
    end
  end
end
