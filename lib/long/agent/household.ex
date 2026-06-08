defmodule Long.Agent.Household do
  @moduledoc """
  A family group — the unit of multi-tenancy for the agent: it
  owns `HouseholdMember` records, and (in later phases) members' sessions,
  skills, and per-member code workspaces are scoped within it.

  A household is deliberately lightweight — just a name and its members.
  Members are the thing that binds chat accounts and addresses each other
  (see `Long.Agent.HouseholdMember`).
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "agent_households"
    repo Long.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:name]
    end

    update :update do
      accept [:name]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :members, Long.Agent.HouseholdMember do
      sort relation: :asc, inserted_at: :asc
    end
  end
end
