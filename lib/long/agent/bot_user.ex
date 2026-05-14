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
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "agent_bot_users"
    repo Long.Repo

    references do
      reference :session, on_delete: :nilify
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:platform, :external_id, :chat_id, :display_name, :session_id, :metadata]
    end

    update :update do
      require_atomic? false
      accept [:chat_id, :display_name, :session_id, :metadata]
    end

    update :rotate_session do
      require_atomic? false
      accept [:session_id]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :platform, :atom do
      constraints one_of: [:telegram, :feishu, :discord, :wechat, :wecom, :dingtalk, :qq]
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
  end

  identities do
    identity :platform_external, [:platform, :external_id]
  end
end
