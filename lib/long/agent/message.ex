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
      # All GraphQL-facing reads go through `internal == false` actions so a
      # silent-reflection turn's monologue never surfaces externally (the
      # /graphql endpoint has no auth pipeline). In-process callers
      # (History/TitleGen/L4) use the unfiltered `:read`/`:by_session`
      # actions directly so reflection continuity survives.
      list :messages, :read_public
      get :message, :read_public
      list :messages_for_session, :by_session_public
    end
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
      pagination keyset?: true, default_limit: 25, max_page_size: 100, required?: false
    end

    # Whole-table read with `internal` (silent-reflection) rows hidden —
    # backs the public GraphQL `messages`/`message` queries. The primary
    # `:read` stays unfiltered for in-process callers (chat.ex filters at
    # render; L4 needs all rows).
    read :read_public do
      filter expr(internal == false)
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
      #
      # NOTE: this action stays UNFILTERED on `internal` — History.replay
      # and TitleGen read through it and MUST keep seeing silent-reflection
      # rows or the agent loses its own cross-turn reflection continuity.
      # The public/GraphQL surface uses `:by_session_public` instead.
      pagination keyset?: true, default_limit: 20, max_page_size: 100, required?: false
    end

    # Same as `:by_session` but hides `internal` (silent-reflection) rows.
    # Backs the GraphQL `messagesForSession` query so a reflection turn's
    # internal monologue never surfaces to external callers.
    read :by_session_public do
      argument :session_id, :uuid, allow_nil?: false
      filter expr(session_id == ^arg(:session_id) and internal == false)
      prepare build(sort: [inserted_at: :asc])
      pagination keyset?: true, default_limit: 20, max_page_size: 100, required?: false
    end

    create :append do
      accept [:role, :content, :blocks, :tool_calls, :tool_results, :turn, :session_id, :internal]
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
      description "Provider-agnostic side-channel, key-discriminated by writer: \"items\" holds Anthropic-style content blocks for replay; \"attachments\" holds web-upload UI refs ({file, kind}). Replay readers must match the key they expect."
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

    attribute :internal, :boolean do
      description "True for rows produced by a silent reflection turn — hidden from the web /chat and the public GraphQL list, but still visible to in-process History/TitleGen replay."
      default false
      allow_nil? false
      # Server-side filters (:read_public / :by_session_public) read this,
      # but it is NOT exposed to GraphQL — external callers can neither
      # select nor filter on it, so the silent-reflection flag stays internal.
      public? false
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
