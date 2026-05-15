defmodule Long.Agent.Activity do
  @moduledoc """
  In-memory registry of in-flight agent loops, keyed by `session_id`.
  Multiple watchers can coexist against the same session; the
  `agent_status` tool queries this to answer "what's running?".

  Backed by a `:public` `:bag` ETS table — `lookup/1` is a direct ETS
  read; only `register/1` and DOWN cleanup go through the GenServer
  (so the `Process.monitor` is set up before the row becomes visible).
  """

  use GenServer

  alias Long.Util.Duration

  @table __MODULE__

  defstruct monitors: %{}

  # ── Public API ───────────────────────────────────────────────────────

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Register the calling process as a watcher for `session_id`."
  @spec register(String.t()) :: {:ok, map()}
  def register(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:register, session_id, self()})
  end

  @doc "Unregister the calling process's entry for `session_id`."
  @spec unregister(String.t()) :: :ok
  def unregister(session_id) when is_binary(session_id) do
    GenServer.cast(__MODULE__, {:unregister, session_id, self()})
  end

  @doc "Merge `fields` into the calling process's entry. No-op if not registered."
  @spec update(String.t(), map()) :: :ok
  def update(session_id, %{} = fields) when is_binary(session_id) do
    pid = self()

    case find_row(session_id, pid) do
      nil -> :ok
      row -> replace_row(row, Map.merge(row, fields))
    end

    :ok
  end

  @doc "List active entries for `session_id`. `[]` when nothing is running."
  @spec lookup(String.t()) :: [map()]
  def lookup(session_id) when is_binary(session_id) do
    @table
    |> :ets.lookup(session_id)
    |> Enum.map(fn {_sid, info} -> info end)
  end

  @doc "Render a one-line status for one entry."
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
    :ets.new(@table, [:named_table, :public, :bag, read_concurrency: true])
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:register, sid, pid}, _from, state) do
    ref = Process.monitor(pid)

    info = %{
      session_id: sid,
      watcher_pid: pid,
      watcher_ref: ref,
      since: System.system_time(:millisecond),
      turn: nil,
      tool: nil
    }

    :ets.insert(@table, {sid, info})
    {:reply, {:ok, info}, %{state | monitors: Map.put(state.monitors, ref, {sid, pid})}}
  end

  @impl true
  def handle_cast({:unregister, sid, pid}, state) do
    {:noreply, drop_pid(sid, pid, state)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, ref) do
      {:ok, {sid, pid}} -> {:noreply, drop_pid(sid, pid, state)}
      :error -> {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── ETS helpers ──────────────────────────────────────────────────────

  defp find_row(sid, pid) do
    Enum.find_value(:ets.lookup(@table, sid), fn
      {_sid, %{watcher_pid: ^pid} = info} -> info
      _ -> nil
    end)
  end

  defp replace_row(old, new) do
    :ets.delete_object(@table, {old.session_id, old})
    :ets.insert(@table, {new.session_id, new})
  end

  defp drop_pid(sid, pid, state) do
    case find_row(sid, pid) do
      nil ->
        state

      %{watcher_ref: ref} = info ->
        _ = Process.demonitor(ref, [:flush])
        :ets.delete_object(@table, {sid, info})
        %{state | monitors: Map.delete(state.monitors, ref)}
    end
  end
end
