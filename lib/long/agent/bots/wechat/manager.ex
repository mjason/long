defmodule Long.Agent.Bots.Wechat.Manager do
  @moduledoc """
  Reconciles running `Long.Agent.Bots.Wechat.Worker`s against stored
  `Long.Agent.WechatCredential` rows — exactly one worker per hosted
  account. This is what lets a group connect several WeChat accounts,
  each `member_id`-bound to a different role.

  Reconciliation runs on boot, on an explicit `reconcile/0`, and whenever
  a credential is connected/deleted (the wechat-login PubSub). Each pass:

    * starts a worker for any credential without one,
    * stops a worker whose credential was deleted,
    * tells already-running workers to `reload/1` (picks up a fresh token
      after a re-login, or a changed `member_id`).
  """
  use GenServer
  require Logger

  alias Long.Agent.Bots.Wechat.{Credential, Worker, WorkerSupervisor}

  @registry Long.Agent.Bots.Wechat.Registry

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Re-sync workers to the current set of stored credentials (synchronous)."
  def reconcile do
    case Process.whereis(__MODULE__) do
      nil -> :no_manager
      _ -> GenServer.call(__MODULE__, :reconcile)
    end
  end

  @impl true
  def init(:ok) do
    {:ok, %{pubsub_ref: subscribe_pubsub()}, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state), do: {:noreply, do_reconcile(state)}

  @impl true
  def handle_call(:reconcile, _from, state), do: {:reply, :ok, do_reconcile(state)}

  @impl true
  def handle_info(:wechat_connected, state), do: {:noreply, do_reconcile(state)}

  # Long.PubSub restarted, taking our subscription with it (under :one_for_one
  # we aren't restarted). Without recovery we'd never hear :wechat_connected
  # again — a fresh login wouldn't start its worker. Re-subscribe + reconcile.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{pubsub_ref: ref} = state) do
    Logger.warning("Wechat.Manager: Long.PubSub went down; re-subscribing and reconciling")
    {:noreply, resubscribe(state)}
  end

  def handle_info(:resubscribe, state), do: {:noreply, resubscribe(state)}
  def handle_info(_other, state), do: {:noreply, state}

  # Subscribe to the wechat-login topic and monitor Long.PubSub so we can detect
  # its restart. Returns the monitor ref (or nil if PubSub isn't up yet).
  defp subscribe_pubsub do
    Credential.subscribe()

    case Process.whereis(Long.PubSub) do
      pid when is_pid(pid) -> Process.monitor(pid)
      _ -> nil
    end
  end

  # Re-establish the subscription after a PubSub restart. If PubSub isn't back
  # yet (tiny race right after its crash), retry shortly rather than give up.
  defp resubscribe(state) do
    case subscribe_pubsub() do
      nil ->
        Process.send_after(self(), :resubscribe, 500)
        %{state | pubsub_ref: nil}

      ref ->
        do_reconcile(%{state | pubsub_ref: ref})
    end
  end

  defp do_reconcile(state) do
    want = MapSet.new(Credential.names())
    have = MapSet.new(running_names())

    Enum.each(MapSet.difference(want, have), &start_worker/1)
    Enum.each(MapSet.difference(have, want), &stop_worker/1)
    Enum.each(MapSet.intersection(want, have), &Worker.reload/1)
    state
  end

  defp running_names, do: Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])

  defp start_worker(name) do
    case DynamicSupervisor.start_child(WorkerSupervisor, {Worker, name: name}) do
      {:ok, _pid} -> Logger.info("Wechat.Manager: started worker for #{name}")
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> Logger.error("Wechat.Manager: start #{name} failed: #{inspect(reason)}")
    end
  end

  defp stop_worker(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(WorkerSupervisor, pid)
        Logger.info("Wechat.Manager: stopped worker for #{name}")

      [] ->
        :ok
    end
  end
end
