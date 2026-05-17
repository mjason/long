defmodule Long.Agent.WorkingCheckpoint do
  @moduledoc """
  L1 working memory: a single `key_info` blob per session, updated in place
  via the GraphQL `putWorkingCheckpoint` mutation. Mirrors GenericAgent's L1 layer.
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshGraphql.Resource]

  sqlite do
    table "agent_working_checkpoints"
    repo Long.Repo

    references do
      reference :session, on_delete: :delete
    end
  end

  graphql do
    type :working_checkpoint

    queries do
      list :working_checkpoints, :read
    end

    mutations do
      create :put_working_checkpoint, :upsert
      destroy :destroy_working_checkpoint, :destroy
    end
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
      pagination keyset?: true, default_limit: 25, max_page_size: 100, required?: false
    end

    create :upsert do
      accept [:session_id, :key_info]
      upsert? true
      upsert_identity :session_id
      upsert_fields [:key_info, :updated_at]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :key_info, :string do
      allow_nil? false
      default ""
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
    identity :session_id, [:session_id]
  end
end
