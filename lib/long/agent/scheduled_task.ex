defmodule Long.Agent.ScheduledTask do
  @moduledoc """
  Phase 5 — port of `sche_tasks/*.json` from Python's `reflect/scheduler.py`.

  Each row is a recurring (or one-shot) prompt to be injected into a session
  on a schedule. `Long.Agent.Workers.SchedulerTick` polls this table once a
  minute (via Oban Cron) and enqueues `Workers.RunScheduledTask` for every
  due row.

  All times are UTC. `schedule_time` is the wall-clock target for daily/
  weekday-style repeats; for `:every_*` repeats we just add the interval to
  `last_run_at`.
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "agent_scheduled_tasks"
    repo Long.Repo

    references do
      reference :session, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :name,
        :session_id,
        :prompt,
        :repeat,
        :schedule_time,
        :every_n,
        :max_delay_hours,
        :enabled,
        :next_run_at,
        :metadata
      ]
    end

    update :update do
      accept [
        :name,
        :prompt,
        :repeat,
        :schedule_time,
        :every_n,
        :max_delay_hours,
        :enabled,
        :next_run_at,
        :metadata
      ]
    end

    update :record_run do
      accept [:last_run_at, :next_run_at]
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

    attribute :prompt, :string do
      description "Synthetic user prompt to inject when this task fires."
      allow_nil? false
      public? true
    end

    attribute :repeat, :atom do
      constraints one_of: [
                    :once,
                    :daily,
                    :weekday,
                    :weekly,
                    :monthly,
                    :every_n_hours,
                    :every_n_minutes
                  ]

      default :daily
      allow_nil? false
      public? true
    end

    attribute :schedule_time, :string do
      description ~s|UTC "HH:MM" for time-of-day-based repeats. Ignored for `:every_*`.|
      default "00:00"
      public? true
    end

    attribute :every_n, :integer do
      description "Interval for `:every_n_hours` / `:every_n_minutes` repeats."
      default 1
      public? true
    end

    attribute :max_delay_hours, :integer do
      description "If we miss the target time by more than this, skip rather than fire late."
      default 6
      public? true
    end

    attribute :enabled, :boolean do
      default true
      allow_nil? false
      public? true
    end

    attribute :last_run_at, :utc_datetime do
      public? true
    end

    attribute :next_run_at, :utc_datetime do
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
