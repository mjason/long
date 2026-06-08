defmodule Long.Agent.Bots.Telegram.Manager do
  @moduledoc """
  Reconciles running `Long.Agent.Bots.Telegram` workers against stored
  `Long.Agent.TelegramCredential` rows — one worker per enabled bot. This
  is what lets a household run several bots, each `member_id`-bound to a
  different role (mirrors `Long.Agent.Bots.Wechat.Manager`).

  Workers are keyed by credential name in `Long.Agent.Bots.Telegram.Registry`;
  `worker_pid/1` resolves a name to its worker so outbound replies go out
  on the right bot. Reconciliation runs on boot and on `reconcile/0`
  (called by the manage UI after a credential is saved/toggled/deleted).
  """
  use GenServer
  require Logger

  alias Long.Agent.Bots.Telegram
  alias Long.Agent.Bots.Telegram.{Credential, WorkerSupervisor}

  @registry Long.Agent.Bots.Telegram.Registry

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Re-sync workers to the current set of enabled credentials (synchronous)."
  def reconcile do
    case Process.whereis(__MODULE__) do
      nil -> :no_manager
      _ -> GenServer.call(__MODULE__, :reconcile)
    end
  end

  @doc "The worker pid for credential `name`, or `nil` if it isn't running."
  @spec worker_pid(String.t()) :: pid() | nil
  def worker_pid(name) when is_binary(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @impl true
  def init(:ok), do: {:ok, :ok, {:continue, :reconcile}}

  @impl true
  def handle_continue(:reconcile, state), do: {:noreply, do_reconcile(state)}

  @impl true
  def handle_call(:reconcile, _from, state), do: {:reply, :ok, do_reconcile(state)}

  defp do_reconcile(state) do
    want = MapSet.new(Credential.enabled_names())
    have = MapSet.new(running_names())

    Enum.each(MapSet.difference(want, have), &start_worker/1)
    Enum.each(MapSet.difference(have, want), &stop_worker/1)
    Enum.each(MapSet.intersection(want, have), &reload_worker/1)
    state
  end

  defp running_names, do: Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])

  defp start_worker(name) do
    spec = {Telegram, credential_name: name, name: {:via, Registry, {@registry, name}}}

    case DynamicSupervisor.start_child(WorkerSupervisor, spec) do
      {:ok, _pid} -> Logger.info("Telegram.Manager: started worker for #{name}")
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> Logger.error("Telegram.Manager: start #{name} failed: #{inspect(reason)}")
    end
  end

  defp stop_worker(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(WorkerSupervisor, pid)
        Logger.info("Telegram.Manager: stopped worker for #{name}")

      [] ->
        :ok
    end
  end

  defp reload_worker(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] -> Telegram.reload(pid)
      [] -> :ok
    end
  end
end
