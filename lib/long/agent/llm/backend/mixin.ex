defmodule Long.Agent.LLM.Backend.Mixin do
  @moduledoc """
  Failover wrapper over an ordered list of backends, port of `MixinSession`.

  - Attempts members in priority order. On error, advances to the next member.
  - After `:spring_back_ms` since the last failover, retries the primary first.
  - `:max_retries` is the total budget across the whole rotation.
  - All members **must implement the same wire-format expectations**; the
    Python version allowed Claude+OAI mixing via Native sessions, but here both
    canonical backends emit the same event shape so failover is format-safe.
  """

  @behaviour Long.Agent.LLM.Backend

  alias Long.Agent.LLM.Backend

  defstruct [
    :name,
    members: [],
    max_retries: 3,
    base_delay_ms: 500,
    spring_back_ms: 300_000
  ]

  @impl true
  def stream_chat(%__MODULE__{members: []}, _msgs, _opts) do
    Stream.unfold(true, fn
      true -> {{:error, :no_members}, false}
      false -> nil
    end)
  end

  def stream_chat(%__MODULE__{} = mixin, messages, opts) do
    init = %{
      mixin: mixin,
      attempt: 0,
      idx: 0,
      iter: nil,
      halted?: false,
      switched_at_ms: 0
    }

    Stream.resource(
      fn -> init end,
      &advance(&1, messages, opts),
      &cleanup/1
    )
  end

  defp advance(%{halted?: true} = state, _msgs, _opts), do: {:halt, state}

  defp advance(%{iter: nil} = state, messages, opts) do
    if state.attempt > state.mixin.max_retries do
      {:halt, %{state | halted?: true}}
    else
      idx = effective_idx(state)
      backend = Enum.at(state.mixin.members, rem(idx, length(state.mixin.members)))
      iter = stream_to_iterator(Backend.stream_chat(backend, messages, opts))
      {[], %{state | iter: iter, idx: idx}}
    end
  end

  defp advance(%{iter: iter} = state, _msgs, _opts) do
    case next_event(iter) do
      {:ok, {:done, _} = ev} ->
        stop_iter(state)
        {[ev], %{state | halted?: true}}

      {:ok, {:error, _} = err} ->
        stop_iter(state)
        new_attempt = state.attempt + 1
        n = length(state.mixin.members)

        if new_attempt > state.mixin.max_retries do
          {[err], %{state | halted?: true}}
        else
          new_idx = rem(state.idx + 1, n)
          maybe_sleep(state.mixin, new_attempt, n)

          {[],
           %{
             state
             | attempt: new_attempt,
               idx: new_idx,
               iter: nil,
               switched_at_ms: System.monotonic_time(:millisecond)
           }}
        end

      {:ok, ev} ->
        {[ev], state}

      :halt ->
        stop_iter(state)
        {:halt, %{state | halted?: true}}
    end
  end

  defp cleanup(state), do: stop_iter(state)

  defp effective_idx(%{idx: 0} = _state), do: 0

  defp effective_idx(%{idx: idx, switched_at_ms: ts, mixin: %{spring_back_ms: spring}}) do
    if ts > 0 and System.monotonic_time(:millisecond) - ts > spring, do: 0, else: idx
  end

  defp maybe_sleep(%{base_delay_ms: base}, attempt, n) do
    round = div(attempt, n)
    if round > 0, do: Process.sleep(min(30_000, trunc(base * :math.pow(1.5, round))))
  end

  # ── Stream → polling iterator bridge ─────────────────────────────────────

  defp stream_to_iterator(stream) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        Enum.each(stream, fn ev -> send(parent, {ref, :ev, ev}) end)
        send(parent, {ref, :done})
      end)

    %{ref: ref, task: task}
  end

  defp next_event(%{ref: ref}) do
    receive do
      {^ref, :ev, ev} -> {:ok, ev}
      {^ref, :done} -> :halt
    after
      120_000 -> {:ok, {:error, :iterator_timeout}}
    end
  end

  defp stop_iter(%{iter: %{task: task}}), do: Task.shutdown(task, :brutal_kill)
  defp stop_iter(_), do: :ok
end
