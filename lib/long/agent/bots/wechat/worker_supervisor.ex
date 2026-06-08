defmodule Long.Agent.Bots.Wechat.WorkerSupervisor do
  @moduledoc """
  DynamicSupervisor holding one `Long.Agent.Bots.Wechat.Worker` per
  hosted WeChat account. Children are started and stopped by
  `Long.Agent.Bots.Wechat.Manager` as credentials come and go.
  """
  use DynamicSupervisor

  def start_link(init_arg),
    do: DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)

  @impl true
  def init(_init_arg), do: DynamicSupervisor.init(strategy: :one_for_one)
end
