defmodule Long.Agent.Monitor do
  @moduledoc """
  A "lambda" monitor: an AI-authored script that runs **periodically** and
  decides for itself whether to notify the user — push only when there's
  something, stay quiet otherwise. The opposite of a `Long.Agent.ScheduledTask`,
  which fires an LLM turn at a fixed time and *always* delivers its reply.

  Each tick `Long.Agent.Workers.RunMonitor` runs `script` in the Deno sandbox
  (no LLM — far cheaper than a scheduled task) and reads the **last stdout JSON
  line** as the decision:

      {"notify": true, "message": "小米盘前 -3.2%，跌破支撑 18.0", "key": "xiaomi-premarket"}

  `notify=false` (or no message) → silent. The script keeps its own "last seen"
  state in workspace files (`Deno.readTextFile`/`writeTextFile`), so the app
  holds no per-monitor state beyond scheduling bookkeeping + dedup anchors.

  `cooldown_minutes` + `last_digest` suppress repeat alerts: the same message
  within the cooldown window, or an identical message, is not re-pushed.

  Scheduling reuses `Long.Agent.Schedule` (via the shared repeat enum) and is
  driven by `Long.Agent.Workers.SchedulerTick`, exactly like ScheduledTask.
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshGraphql.Resource]

  sqlite do
    table "agent_monitors"
    repo Long.Repo

    references do
      reference :session, on_delete: :delete
    end
  end

  graphql do
    type :monitor

    queries do
      list :monitors, :read
      get :monitor, :read
      list :monitors_for_session, :by_session
    end

    mutations do
      create :create_monitor, :create
      update :update_monitor, :update
      update :disable_monitor, :disable
      destroy :destroy_monitor, :destroy
    end
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
      pagination keyset?: true, default_limit: 25, max_page_size: 100, required?: false
    end

    read :by_session do
      argument :session_id, :uuid, allow_nil?: false
      filter expr(session_id == ^arg(:session_id))
      prepare build(sort: [name: :asc])
      pagination keyset?: true, default_limit: 25, max_page_size: 100, required?: false
    end

    create :create do
      accept [
        :name,
        :session_id,
        :script,
        :language,
        :repeat,
        :schedule_time,
        :every_n,
        :max_delay_hours,
        :cooldown_minutes,
        :enabled,
        :next_run_at,
        :secret_name,
        :metadata
      ]
    end

    update :update do
      # Accepts the `metadata` map (see record_run note on atomic + :map).
      require_atomic? false

      accept [
        :name,
        :script,
        :language,
        :repeat,
        :schedule_time,
        :every_n,
        :max_delay_hours,
        :cooldown_minutes,
        :enabled,
        :next_run_at,
        :secret_name,
        :metadata
      ]
    end

    update :record_run do
      # Writes the `last_output` map; atomic updates don't JSON-encode :map in
      # AshSqlite, so run it as a regular (cast-everything) update.
      require_atomic? false
      accept [:last_run_at, :next_run_at, :last_notified_at, :last_status, :last_output, :last_digest]
    end

    update :disable do
      change set_attribute(:enabled, false)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :script, :string do
      description "The AI-authored script. Prints a JSON decision line to stdout: {notify, message, key?}."
      allow_nil? false
      public? true
    end

    attribute :language, :string do
      description "Script runtime. Only `deno` (TypeScript/JavaScript) today."
      default "deno"
      public? true
    end

    attribute :repeat, Long.Agent.Enums.ScheduledTaskRepeat do
      description "How often to run. `:every_n_minutes` is the typical monitor cadence."
      default :every_n_minutes
      allow_nil? false
      public? true
    end

    attribute :schedule_time, :string do
      description ~s|UTC "HH:MM" for time-of-day repeats. Ignored for `:every_*`.|
      default "00:00"
      public? true
    end

    attribute :every_n, :integer do
      description "Interval for `:every_n_minutes` / `:every_n_hours`."
      default 5
      public? true
    end

    attribute :max_delay_hours, :integer do
      description "If a run window is missed by more than this, skip rather than run late."
      default 6
      public? true
    end

    attribute :cooldown_minutes, :integer do
      description "Suppress a repeat notification within this window (0 = no cooldown)."
      default 0
      public? true
    end

    attribute :enabled, :boolean do
      default true
      allow_nil? false
      public? true
    end

    attribute :secret_name, :string do
      description "Optional secret to expose to the script as the SECRET env var."
      public? true
    end

    attribute :last_run_at, :utc_datetime do
      public? true
    end

    attribute :next_run_at, :utc_datetime do
      public? true
    end

    attribute :last_notified_at, :utc_datetime do
      public? true
    end

    attribute :last_status, :string do
      description "Outcome of the last run: notified / silent / error."
      public? true
    end

    attribute :last_output, :map do
      description "Parsed decision + a tail of stdout from the last run (for the admin panel)."
      default %{}
      public? true
    end

    attribute :last_digest, :string do
      description "Hash of the last NOTIFIED message — skip an identical repeat alert."
      public? true
    end

    attribute :metadata, :map do
      default %{}
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :session, Long.Agent.Session do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :name, [:name]
  end
end
