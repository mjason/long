defmodule Long.Agent.MonitorRun do
  @moduledoc """
  One recorded execution of a `Long.Agent.Monitor` — the execution history the
  admin panel and the agent can look at ("did it run? what did it decide? why
  didn't it notify? what errored?").

  Only **notable** runs are stored: a notification, a suppressed notification
  (cooldown / unchanged), or an error. The boring silent heartbeat (`no_notify`)
  is NOT recorded — the monitor's own `last_run_at` / `last_status` already shows
  the latest tick, so recording every 5-minute "nothing happened" would just be
  noise. `RunMonitor` prunes to the newest `@keep_runs` per monitor.
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshGraphql.Resource]

  sqlite do
    table "agent_monitor_runs"
    repo Long.Repo

    # The by_monitor read (admin panel + prune) filters monitor_id and sorts
    # inserted_at desc — index exactly that so it stays cheap as history grows.
    custom_indexes do
      index [:monitor_id, :inserted_at]
    end

    references do
      reference :monitor, on_delete: :delete
    end
  end

  graphql do
    type :monitor_run

    queries do
      list :runs_for_monitor, :by_monitor
    end
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
      pagination keyset?: true, default_limit: 50, max_page_size: 200, required?: false
    end

    read :by_monitor do
      argument :monitor_id, :uuid, allow_nil?: false
      filter expr(monitor_id == ^arg(:monitor_id))
      prepare build(sort: [inserted_at: :desc])
      pagination keyset?: true, default_limit: 50, max_page_size: 200, required?: false
    end

    create :create do
      accept [:monitor_id, :status, :decision, :message, :stdout_tail, :ran_at]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :string do
      description "notified / silent / error (matches the monitor's last_status)."
      allow_nil? false
      public? true
    end

    attribute :decision, :string do
      description "Sub-reason: notified, suppressed_cooldown, suppressed_unchanged, unparseable, exit_N, ..."
      public? true
    end

    attribute :message, :string do
      description "The message the script wanted to push (when it asked to notify)."
      public? true
    end

    attribute :stdout_tail, :string do
      description "Tail of the script's stdout for this run (debugging)."
      public? true
    end

    attribute :ran_at, :utc_datetime do
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :monitor, Long.Agent.Monitor do
      allow_nil? false
      public? true
    end
  end
end
