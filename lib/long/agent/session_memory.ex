defmodule Long.Agent.SessionMemory do
  @moduledoc """
  Per-session structured memory: facts, preferences, goals, decisions
  that the agent picks up during a conversation and should keep
  accessible across turns of the *same* session.

  Lives next to `Long.Agent.GlobalMemory` (cross-session) and is
  populated/queried via the `memory_remember` / `memory_recall` tools.
  At Loop entry, the top-K most relevant rows are also pulled
  automatically and folded into the system prompt addendum, so the
  agent doesn't need to explicitly call `memory_recall` to surface
  background context.

  Identity: `(session_id, key)` — upserts by name within a session.
  Cross-session sharing happens via `GlobalMemory` instead.
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer

  require Ash.Query
  import Ash.Expr

  sqlite do
    table "agent_session_memories"
    repo Long.Repo

    references do
      reference :session, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    read :by_session do
      argument :session_id, :uuid, allow_nil?: false
      filter expr(session_id == ^arg(:session_id))
      prepare build(sort: [importance: :desc, updated_at: :desc])
    end

    create :upsert do
      accept [:session_id, :key, :value, :kind, :importance]
      upsert? true
      upsert_identity :session_key
      upsert_fields [:value, :kind, :importance, :updated_at]
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

    attribute :kind, :atom do
      constraints one_of: [:fact, :preference, :goal, :decision]
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
