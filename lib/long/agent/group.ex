defmodule Long.Agent.Group do
  @moduledoc """
  A group — the unit of multi-tenancy for the agent: it
  owns `Member` records, and (in later phases) members' sessions,
  skills, and per-member code workspaces are scoped within it.

  A group is deliberately lightweight — just a name and its members.
  Members are the thing that binds chat accounts and addresses each other
  (see `Long.Agent.Member`).
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "agent_groups"
    repo Long.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:name, :locale]
    end

    update :update do
      accept [:name, :locale]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :locale, :string do
      description "Default language for this group's bots (e.g. \"zh\"). Falls back to the system default when nil."
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :members, Long.Agent.Member do
      sort relation: :asc, inserted_at: :asc
    end
  end
end
