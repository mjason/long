defmodule Long.Agent.Message do
  @moduledoc """
  One message in a session: system/user/assistant/tool. `blocks` keeps the raw
  multi-block representation (text, tool_use, tool_result, thinking) so we can
  replay a turn faithfully to any LLM provider; `content` is a flattened text
  preview for UI/search.
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshGraphql.Resource]

  require Ash.Query
  import Ash.Expr

  sqlite do
    table "agent_messages"
    repo Long.Repo

    references do
      reference :session, on_delete: :delete
    end
  end

  graphql do
    type :message

    # Read-only from the AI's perspective; messages are written by
    # Long.Agent.Server during the loop and shouldn't be mutated
    # directly from GraphQL (that would corrupt the conversation).
    queries do
      list :messages, :read
      get :message, :read
      list :messages_for_session, :by_session
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
      prepare build(sort: [inserted_at: :asc])
      # Message rows can carry kilobytes of `blocks` JSON — keep the
      # default page small to protect LLM context. GraphQL callers
      # paginate; in-process callers (History/TitleGen) ignore the
      # limit because paginate_by_default? is false.
      pagination keyset?: true, default_limit: 20, max_page_size: 100, required?: false
    end

    create :append do
      accept [:role, :content, :blocks, :tool_calls, :tool_results, :turn, :session_id]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, Long.Agent.Enums.MessageRole do
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
