defmodule Long.Agent.GlobalMemory do
  @moduledoc """
  L2 global memory entries. GenericAgent stores these in `memory/global_mem.txt`
  and `memory/global_mem_insight.txt`; here we model them as rows keyed by
  `{scope, key}` so they can be queried, edited via AshAdmin, and versioned via
  timestamps.
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
      accept [:scope, :key, :value]
      upsert? true
      upsert_identity :scope_key
      upsert_fields [:value, :updated_at]
    end

    update :update do
      accept [:value]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :scope, :atom do
      constraints one_of: [:general, :insight]
      default :general
      allow_nil? false
      public? true
    end

    attribute :key, :string do
      allow_nil? false
      public? true
    end

    attribute :value, :string do
      allow_nil? false
      default ""
      public? true
    end

    timestamps()
  end

  identities do
    identity :scope_key, [:scope, :key]
  end
end
