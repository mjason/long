defmodule Long.Agent.Setting do
  @moduledoc """
  System-wide operator settings — small key/value config the agent *reads*
  but does not own as memory (e.g. `user_timezone`).

  Distinct from `Long.Agent.GlobalMemory`, which is the LLM's own memory:
  settings are not dumped into the prompt's memory section, and the LLM can't
  freely write them via GraphQL — changes go through a dedicated tool (e.g.
  `set_timezone`) or the admin UI. Identity: `key`.
  """
  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "agent_settings"
    repo Long.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      accept [:key, :value]
      upsert? true
      upsert_identity :unique_key
      upsert_fields [:value, :updated_at]
    end
  end

  attributes do
    uuid_primary_key :id

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
    identity :unique_key, [:key]
  end
end
