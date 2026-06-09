defmodule Long.Agent.BotUser do
  @moduledoc """
  Phase 7 — maps an external chat platform's user to the agent session that
  carries their ongoing conversation.

  One row per `(platform, external_id)`. The `session_id` points at the
  current session; when the user issues a "/reset"-style command the
  adapter can rotate it.

  - `:platform` — `:telegram | :feishu | :discord | :wechat | :wecom |
    :dingtalk | :qq`
  - `:external_id` — platform's stable user identifier (Telegram `user.id`
    stringified, Feishu `open_id`, …)
  - `:chat_id` — where to send the reply (often equal to `external_id`, but
    differs for group chats)
  - `:metadata` — platform-specific bag (locale, raw user object, …)
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshGraphql.Resource]

  require Ash.Query
  import Ash.Expr

  sqlite do
    table "agent_bot_users"
    repo Long.Repo

    references do
      reference :session, on_delete: :nilify
      reference :member, on_delete: :nilify
    end
  end

  graphql do
    # Read-only — bot users are created/managed by platform adapters
    # (wechat / feishu / telegram workers). The AI can query to see
    # "who am I talking to and via what channel" but shouldn't write.
    type :bot_user

    queries do
      list :bot_users, :read
      get :bot_user_for_session, :by_session
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
      get? true
    end

    create :create do
      accept [
        :platform,
        :external_id,
        :chat_id,
        :display_name,
        :session_id,
        :member_id,
        :credential_name,
        :metadata
      ]
    end

    update :update do
      require_atomic? false
      accept [:chat_id, :display_name, :session_id, :member_id, :credential_name, :metadata]
    end

    update :rotate_session do
      require_atomic? false
      accept [:session_id]
    end

    update :bind_member do
      require_atomic? false
      accept [:member_id]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :platform, Long.Agent.Enums.BotPlatform do
      allow_nil? false
      public? true
    end

    attribute :external_id, :string do
      allow_nil? false
      public? true
    end

    attribute :chat_id, :string do
      public? true
    end

    attribute :credential_name, :string do
      description "Which hosted account/bot this chat arrived on (the WechatCredential / TelegramCredential `name`). Outbound replies go back via this exact channel."
      public? true
    end

    attribute :display_name, :string do
      public? true
    end

    attribute :metadata, :map do
      default %{}
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :session, Long.Agent.Session do
      allow_nil? true
      public? true
    end

    belongs_to :member, Long.Agent.Member do
      description "The group member who claimed this chat account, if bound."
      allow_nil? true
      public? true
    end
  end

  identities do
    identity :platform_external, [:platform, :external_id]
  end
end
