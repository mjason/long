defmodule Long.Agent.Session do
  @moduledoc """
  A single conversation/run of the agent. Owns messages and one working checkpoint.
  Equivalent to GenericAgent's in-memory session held by `agentmain.GenericAgent`.
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "agent_sessions"
    repo Long.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :start do
      accept [:title, :llm_alias]
    end

    update :update do
      accept [
        :title,
        :title_locked,
        :status,
        :llm_alias,
        :summary,
        :summary_through_inserted_at,
        :token_usage,
        :ended_at
      ]
    end

    update :archive do
      change set_attribute(:status, :archived)
      change set_attribute(:ended_at, &DateTime.utc_now/0)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :title_locked, :boolean do
      description "True once the user has manually saved a title — keeps `Long.Jido.TitleGen` from overwriting it on the next loop_ended."
      default false
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:active, :archived, :errored]
      default :active
      allow_nil? false
      public? true
    end

    attribute :llm_alias, :string do
      public? true
    end

    attribute :summary, :string do
      description "LLM-generated condensation of the conversation prefix that no longer fits in the context window."
      public? true
    end

    attribute :summary_through_inserted_at, :utc_datetime_usec do
      description "All messages with inserted_at <= this timestamp are covered by `:summary`. Subsequent messages stay in raw context."
      public? true
    end

    attribute :token_usage, :integer do
      default 0
      allow_nil? false
      public? true
    end

    attribute :ended_at, :utc_datetime do
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :messages, Long.Agent.Message do
      sort turn: :asc, inserted_at: :asc
    end

    has_one :working_checkpoint, Long.Agent.WorkingCheckpoint
  end
end
