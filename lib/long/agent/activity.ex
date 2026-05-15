defmodule Long.Agent.Activity do
  @moduledoc """
  Per-session activity tracker. Three responsibilities:

    1. **Slot ownership** — only one watcher (agent loop) processes a
       session at a time. `try_acquire_or_enqueue/2` is atomic.
    2. **Pending message queue** — inbound messages arriving while a
       watcher holds the slot get queued and drained in order by that
       watcher before it releases.
    3. **Mid-flight `/btw` notes** — short context additions the user
       wants the running agent to pick up *during* its current turn
       (no new loop). `Long.Jido.Loop` reads pending btws between LLM
       calls and injects them as user-role messages.

  All state in named ETS owned by the GenServer; reads are direct,
  writes that need ownership go through the GenServer.
  """

  use GenServer

  alias Long.Util.Duration

  @owners __MODULE__.Owners
  @queues __MODULE__.Queues
  @btws __MODULE__.Btws

  defstruct monitors: %{}

  # ── Public API ───────────────────────────────────────────────────────

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Atomically claim the slot for `session_id`. If free, the calling
  process becomes the owner and `:acquired` is returned (caller must
  later call `release/1`). If occupied, `payload` is appended to the
  pending queue and `:enqueued` is returned.
  """
  @spec try_acquire_or_enqueue(String.t(), term()) :: :acquired | :enqueued
  def try_acquire_or_enqueue(session_id, payload) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:acquire_or_enqueue, session_id, self(), payload})
  end

  @doc """
  Pop the next pending payload for `session_id`. Returns `nil` when
  empty. Called by the active watcher in its drain loop right before
  it releases the slot.
  """
  @spec dequeue(String.t()) :: term() | nil
  def dequeue(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:dequeue, session_id})
  end

  @doc "Release the slot owned by the caller for `session_id`."
  @spec release(String.t()) :: :ok
  def release(session_id) when is_binary(session_id) do
    GenServer.cast(__MODULE__, {:release, session_id, self()})
  end

  @doc "Merge `fields` into the owner's info row. No-op if the caller doesn't own the slot."
  @spec update(String.t(), map()) :: :ok
  def update(session_id, %{} = fields) when is_binary(session_id) do
    pid = self()

    case :ets.lookup(@owners, session_id) do
      [{^session_id, %{watcher_pid: ^pid} = info}] ->
        :ets.insert(@owners, {session_id, Map.merge(info, fields)})

      _ ->
        :ok
    end

    :ok
  end

  @doc "Return the current owner info for `session_id`, or `nil`."
  @spec lookup(String.t()) :: map() | nil
  def lookup(session_id) when is_binary(session_id) do
    case :ets.lookup(@owners, session_id) do
      [{^session_id, info}] -> info
      [] -> nil
    end
  end

  @doc """
  Full snapshot — owner info (may be nil), queue depth, pending btw
  count. Used by the `/status` command and the `agent_status` tool.
  """
  @spec snapshot(String.t()) :: %{owner: map() | nil, queue_length: non_neg_integer(), pending_btws: non_neg_integer()}
  def snapshot(session_id) when is_binary(session_id) do
    %{
      owner: lookup(session_id),
      queue_length: queue_length(session_id),
      pending_btws: btw_count(session_id)
    }
  end

  defp queue_length(sid) do
    case :ets.lookup(@queues, sid) do
      [{^sid, q}] -> :queue.len(q)
      [] -> 0
    end
  end

  defp btw_count(sid) do
    case :ets.lookup(@btws, sid) do
      [{^sid, list}] -> length(list)
      [] -> 0
    end
  end

  @doc "Append a mid-flight context note for the active agent on `session_id`."
  @spec add_btw(String.t(), String.t()) :: :ok
  def add_btw(session_id, text) when is_binary(session_id) and is_binary(text) do
    GenServer.call(__MODULE__, {:add_btw, session_id, text})
  end

  @doc """
  Atomically take and clear pending btws for `session_id`. Called by
  `Loop.loop/1` between iterations.

  Fast path: when there are no pending btws (the common case), we
  short-circuit on the ETS read and skip the GenServer round-trip.
  Concurrent `add_btw` callers serialize through the GenServer, so a
  btw landing exactly between the lookup and a hypothetical `take`
  call would be picked up on the next turn — acceptable.
  """
  @spec take_btws(String.t()) :: [String.t()]
  def take_btws(session_id) when is_binary(session_id) do
    case :ets.lookup(@btws, session_id) do
      [] -> []
      _ -> GenServer.call(__MODULE__, {:take_btws, session_id})
    end
  end

  @doc """
  Wipe all activity state for `session_id` — owner row, pending queue,
  pending btws. Demonitors the current owner pid so a subsequent DOWN
  doesn't re-trigger cleanup. Returns `{owner_pid_or_nil, :ok}` so the
  caller can kill the prior watcher without a separate `lookup/1` hop.
  """
  @spec clear(String.t()) :: {pid() | nil, :ok}
  def clear(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:clear, session_id})
  end

  @doc "Render a one-line status describing one owner info entry."
  @spec describe(map()) :: String.t()
  def describe(info) when is_map(info) do
    secs = Duration.seconds_since(info.since)
    "运行中 #{Duration.format_zh(secs)}#{describe_detail(info[:turn], info[:tool])}"
  end

  defp describe_detail(nil, nil), do: ""
  defp describe_detail(turn, nil) when is_integer(turn), do: " · 第 #{turn} 轮"
  defp describe_detail(nil, tool) when is_binary(tool), do: " · 当前工具 `#{tool}`"

  defp describe_detail(turn, tool) when is_integer(turn) and is_binary(tool),
    do: " · 第 #{turn} 轮 · 当前工具 `#{tool}`"

  # ── GenServer ────────────────────────────────────────────────────────

  @impl true
  def init(_) do
    :ets.new(@owners, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@queues, [:named_table, :public, :set])
    :ets.new(@btws, [:named_table, :public, :set])
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:acquire_or_enqueue, sid, pid, payload}, _from, state) do
    case :ets.lookup(@owners, sid) do
      [{^sid, _}] ->
        push_queue(sid, payload)
        {:reply, :enqueued, state}

      [] ->
        {:reply, :acquired, register_owner(sid, pid, state)}
    end
  end

  def handle_call({:dequeue, sid}, _from, state) do
    case pop_queue(sid) do
      :empty -> {:reply, nil, state}
      {:value, payload} -> {:reply, payload, state}
    end
  end

  def handle_call({:add_btw, sid, text}, _from, state) do
    current = case :ets.lookup(@btws, sid) do
      [{^sid, list}] -> list
      [] -> []
    end

    :ets.insert(@btws, {sid, current ++ [text]})
    {:reply, :ok, state}
  end

  def handle_call({:take_btws, sid}, _from, state) do
    list =
      case :ets.lookup(@btws, sid) do
        [{^sid, list}] -> list
        [] -> []
      end

    :ets.delete(@btws, sid)
    {:reply, list, state}
  end

  def handle_call({:clear, sid}, _from, state) do
    {prior_pid, state} =
      case :ets.lookup(@owners, sid) do
        [{^sid, %{watcher_ref: ref, watcher_pid: pid}}] ->
          _ = Process.demonitor(ref, [:flush])
          {pid, %{state | monitors: Map.delete(state.monitors, ref)}}

        _ ->
          {nil, state}
      end

    :ets.delete(@owners, sid)
    :ets.delete(@queues, sid)
    :ets.delete(@btws, sid)
    {:reply, {prior_pid, :ok}, state}
  end

  @impl true
  def handle_cast({:release, sid, pid}, state) do
    {:noreply, drop_owner(sid, pid, state)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, ref) do
      {:ok, {sid, pid}} -> {:noreply, drop_owner(sid, pid, state)}
      :error -> {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── helpers ──────────────────────────────────────────────────────────

  defp register_owner(sid, pid, state) do
    ref = Process.monitor(pid)

    info = %{
      session_id: sid,
      watcher_pid: pid,
      watcher_ref: ref,
      since: System.system_time(:millisecond),
      turn: nil,
      tool: nil
    }

    :ets.insert(@owners, {sid, info})
    %{state | monitors: Map.put(state.monitors, ref, {sid, pid})}
  end

  defp drop_owner(sid, pid, state) do
    case :ets.lookup(@owners, sid) do
      [{^sid, %{watcher_pid: ^pid, watcher_ref: ref}}] ->
        _ = Process.demonitor(ref, [:flush])
        :ets.delete(@owners, sid)
        %{state | monitors: Map.delete(state.monitors, ref)}

      _ ->
        state
    end
  end

  defp push_queue(sid, payload) do
    q =
      case :ets.lookup(@queues, sid) do
        [{^sid, q}] -> q
        [] -> :queue.new()
      end

    :ets.insert(@queues, {sid, :queue.in(payload, q)})
  end

  defp pop_queue(sid) do
    case :ets.lookup(@queues, sid) do
      [{^sid, q}] ->
        case :queue.out(q) do
          {{:value, payload}, rest} ->
            if :queue.is_empty(rest), do: :ets.delete(@queues, sid), else: :ets.insert(@queues, {sid, rest})
            {:value, payload}

          {:empty, _} ->
            :ets.delete(@queues, sid)
            :empty
        end

      [] ->
        :empty
    end
  end
end
