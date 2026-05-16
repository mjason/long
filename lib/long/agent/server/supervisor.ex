defmodule Long.Agent.Server.Supervisor do
  @moduledoc """
  DynamicSupervisor that owns the per-session `Long.Agent.Server`
  GenServers. Each session is started on demand by
  `Long.Agent.Server.send_user_message/3` and stays alive until
  explicitly terminated (e.g. via the `/clear` magic command).

  Restart strategy is `:transient` — if a Server crashes with an
  abnormal reason the supervisor will restart it, which means the
  state machine re-initializes via `init/1`, reads the most recent
  `Long.Agent.TurnSnapshot` for that session, and resumes from that
  snapshot. Normal exits (after a `/clear` triggered terminate, idle
  shutdown timer, …) stay dead.
  """

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 5,
      max_seconds: 30
    )
  end
end
