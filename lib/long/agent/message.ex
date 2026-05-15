defmodule Long.Agent.Message do
  @moduledoc """
  One message in a session: system/user/assistant/tool. `blocks` keeps the raw
  multi-block representation (text, tool_use, tool_result, thinking) so we can
  replay a turn faithfully to any LLM provider; `content` is a flattened text
  preview for UI/search.
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer

  require Ash.Query
  import Ash.Expr

  sqlite do
    table "agent_messages"
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
      prepare build(sort: [inserted_at: :asc])
    end

    create :append do
      accept [:role, :content, :blocks, :tool_calls, :tool_results, :turn, :session_id]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom do
      constraints one_of: [:system, :user, :assistant, :tool]
      allow_nil? false
      public? true
    end

    attribute :content, :string do
      public? true
    end

    attribute :blocks, :map do
      description "Raw LLM content blocks (Anthropic-style list of dicts) for faithful replay."
      public? true
    end

    attribute :tool_calls, {:array, :map} do
      default []
      public? true
    end

    attribute :tool_results, {:array, :map} do
      default []
      public? true
    end

    attribute :turn, :integer do
      default 0
      allow_nil? false
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
end
