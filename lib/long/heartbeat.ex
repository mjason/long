defmodule Long.Heartbeat do
  @moduledoc """
  A tiny liveness registry: each long-running loop calls `beat/1` when it does
  a unit of work, and observers (`Long.Agent.SchedulerWatchdog`, the `/healthz`
  endpoint) read freshness with `age_ms/1` / `all/0`.

  This turns "alive process, not doing work" hangs — which OTP supervision can't
  see (it only reacts to *crashes*) — into something detectable: a loop that
  stops beating goes stale, and a watcher can alert or recover.

  ## Design

  - Backed by one `:public` named ETS table so `beat/1` is a direct, lock-light
    `:ets.insert` from any process (no GenServer round-trip on the hot path).
  - This GenServer owns the table and has **no other logic**, so it effectively
    never crashes. If it ever did restart, the table comes back empty and every
    `age_ms/1` reads `nil` ("never beat") until the next beat — readers treat
    `nil` as "no judgement", so an owner restart can't cause a false alarm.
  - Timestamps are **monotonic** ms, so a host suspend / wall-clock jump can't by
    itself look like staleness.

  Sources are arbitrary terms — `:scheduler`, `{:telegram, name}`,
  `{:wechat, name}`, … — so a new loop can register just by calling `beat/1`.
  """

  use GenServer

  @table __MODULE__

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Record that `source` just did work. Direct ETS write; no-op if the table isn't up."
  @spec beat(term()) :: :ok
  def beat(source) do
    if table?(), do: :ets.insert(@table, {source, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc "Monotonic ms of `source`'s last beat, or `nil` if it has never beaten."
  @spec last_ms(term()) :: integer() | nil
  def last_ms(source) do
    with true <- table?(),
         [{^source, ms}] <- :ets.lookup(@table, source) do
      ms
    else
      _ -> nil
    end
  end

  @doc "Milliseconds since `source`'s last beat, or `nil` if it has never beaten."
  @spec age_ms(term()) :: integer() | nil
  def age_ms(source) do
    case last_ms(source) do
      nil -> nil
      ms -> System.monotonic_time(:millisecond) - ms
    end
  end

  @doc "All `{source, last_ms}` pairs currently recorded."
  @spec all() :: [{term(), integer()}]
  def all, do: if(table?(), do: :ets.tab2list(@table), else: [])

  defp table?, do: :ets.whereis(@table) != :undefined

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    {:ok, %{}}
  end
end
