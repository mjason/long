defmodule Long.Agent.Activity.Tables do
  @moduledoc """
  Owns the ETS tables behind `Long.Agent.Activity` so they OUTLIVE an Activity
  crash.

  `Long.Agent.Activity` holds every in-flight session's slot ownership in these
  tables. When Activity itself owned them, an Activity crash (a one-line bug
  anywhere in a `handle_call`) silently wiped all that cross-process state while
  the agent loops kept running — orphaned slots, broken DOWN-based cleanup,
  two watchers on one session. Parking the tables in this do-nothing process,
  started *before* Activity in the supervision tree, keeps the data intact
  across an Activity restart; Activity then re-monitors the survivors in its
  `init/1`. This process has no logic of its own, so it effectively never
  crashes — and is therefore a safe long-lived home for the tables.
  """

  use GenServer

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    Long.Agent.Activity.ensure_tables()
    {:ok, %{}}
  end
end
