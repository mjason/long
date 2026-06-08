defmodule Long.Agent.Bots.Telegram.WorkerSupervisor do
  @moduledoc """
  DynamicSupervisor holding one `Long.Agent.Bots.Telegram` worker per
  enabled bot credential. Children are started/stopped by
  `Long.Agent.Bots.Telegram.Manager` as credentials change.
  """
  use DynamicSupervisor

  def start_link(init_arg),
    do: DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)

  @impl true
  def init(_init_arg), do: DynamicSupervisor.init(strategy: :one_for_one)
end
