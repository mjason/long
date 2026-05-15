defmodule Long.Agent.GlobalMemory do
  @moduledoc """
  System-wide memory rows — facts/preferences/decisions that should
  survive across every session. The agent reads & writes these via the
  `memory_remember(scope: "global", …)` / `memory_recall(scope:
  "global", …)` tools, and at Loop entry the most relevant rows are
  auto-injected into the system prompt addendum.

  Companion to `Long.Agent.SessionMemory`, which is scoped to a single
  conversation. Identity: `(scope, key)`.
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "agent_global_memory"
    repo Long.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      accept [:scope, :key, :value, :kind, :importance]
      upsert? true
      upsert_identity :scope_key
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

    attribute :scope, :atom do
      description "Coarse bucket — keeps casual facts apart from distilled lessons."
      constraints one_of: [:general, :insight]
      default :general
      allow_nil? false
      public? true
    end

    attribute :key, :string do
      description "Stable identifier so future writes upsert the same row."
      allow_nil? false
      public? true
    end

    attribute :value, :string do
      description "The actual content in natural language."
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
      description "How many times this memory has been surfaced."
      default 0
      allow_nil? false
      public? true
    end

    attribute :last_used_at, :utc_datetime_usec do
      description "Most recent surfacing — recency boost in ranking."
      public? true
    end

    timestamps()
  end

  identities do
    identity :scope_key, [:scope, :key]
  end
end
