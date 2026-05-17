defmodule Long.Agent.SessionMemory do
  @moduledoc """
  Per-session structured memory: facts, preferences, goals, decisions
  that the agent picks up during a conversation and should keep
  accessible across turns of the *same* session.

  Lives next to `Long.Agent.GlobalMemory` (cross-session). The agent
  reads/writes via GraphQL (`putSessionMemory` mutation /
  `sessionMemoriesForSession` query). At Loop entry the top-K most
  relevant rows are auto-injected into the system prompt addendum so
  the agent rarely needs to query explicitly.

  Identity: `(session_id, key)` — upserts by name within a session.
  Cross-session sharing happens via `GlobalMemory` instead.
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshGraphql.Resource]

  require Ash.Query
  import Ash.Expr

  sqlite do
    table "agent_session_memories"
    repo Long.Repo

    references do
      reference :session, on_delete: :delete
    end
  end

  graphql do
    type :session_memory

    queries do
      list :session_memories, :read
      get :session_memory, :read
      list :session_memories_for_session, :by_session
    end

    mutations do
      create :put_session_memory, :upsert
      update :update_session_memory, :update
      destroy :destroy_session_memory, :destroy
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
      prepare build(sort: [importance: :desc, updated_at: :desc])
      pagination keyset?: true, default_limit: 25, max_page_size: 100, required?: false
    end

    create :upsert do
      accept [:session_id, :key, :value, :kind, :importance]
      upsert? true
      upsert_identity :session_key
      upsert_fields [:value, :kind, :importance, :updated_at]
    end

    update :update do
      accept [:value, :kind, :importance]
    end

    update :bump_usage do
      accept []

      change fn changeset, _ ->
        current = Ash.Changeset.get_attribute(changeset, :hit_count) || 0

        changeset
        |> Ash.Changeset.force_change_attribute(:hit_count, current + 1)
        |> Ash.Changeset.force_change_attribute(:last_used_at, DateTime.utc_now())
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      description "Short identifier — used to upsert the same fact later."
      allow_nil? false
      public? true
    end

    attribute :value, :string do
      description "The actual fact/preference/goal/decision in natural language."
      allow_nil? false
      default ""
      public? true
    end

    attribute :kind, Long.Agent.Enums.MemoryKind do
      default :fact
      allow_nil? false
      public? true
    end

    attribute :importance, :integer do
      description "1 (trivial) … 5 (critical). Drives ranking when budgets are tight."
      default 3
      allow_nil? false
      public? true
    end

    attribute :hit_count, :integer do
      description "How many times this memory has been surfaced (auto + explicit recall)."
      default 0
      allow_nil? false
      public? true
    end

    attribute :last_used_at, :utc_datetime_usec do
      description "Most recent surfacing — used as a recency boost in ranking."
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
    identity :session_key, [:session_id, :key]
  end
end
