defmodule Long.Agent.TelegramCredential do
  @moduledoc """
  Stored Telegram bot credentials, read by `Long.Agent.Bots.Telegram`
  at boot and on `:reload`. One row per bot (identity on `:name`, default
  `"default"`). Multiple enabled rows are supported so a group can
  run several bots, each `member_id`-bound to a different role;
  `Long.Agent.Bots.Telegram.Manager` runs one worker per enabled row.

  The token is sensitive — redacted in logs / inspect output. The
  optional `:username` is the bot's `@handle` cached on first
  successful connect so the UI can show "@my_long_bot" instead of
  just "token set".

  When `enabled: false` the credential exists in the DB but the
  worker pauses polling — same shape as just deleting the row, but
  preserves the token so toggling back on is one click.
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "agent_telegram_credentials"
    repo Long.Repo

    references do
      reference :member, on_delete: :nilify
    end
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      upsert? true
      upsert_identity :name
      accept [:name, :bot_token, :username, :enabled, :member_id, :locale]
    end

    update :update do
      accept [:bot_token, :username, :enabled]
    end

    update :update_username do
      accept [:username]
    end

    update :set_member do
      require_atomic? false
      accept [:member_id]
    end

    update :set_locale do
      require_atomic? false
      accept [:locale]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      description "Logical credential name. Single bot deployments leave this as 'default'."
      default "default"
      allow_nil? false
      public? true
    end

    attribute :bot_token, :string do
      description "BotFather token (e.g. \"123456:ABC-DEF…\"). Sensitive — redacted in logs."
      sensitive? true
      allow_nil? false
      public? true
    end

    attribute :username, :string do
      description "Bot's @handle, fetched from getMe on first connect and cached for display."
      public? true
    end

    attribute :enabled, :boolean do
      description "When false, the credential is kept but the worker pauses long-polling."
      default true
      allow_nil? false
      public? true
    end

    attribute :locale, :string do
      description "Language for this bot's outbound copy (e.g. \"zh\"), overriding member/group. Nil = inherit."
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :member, Long.Agent.Member do
      description "The group member (role) this bot serves, if assigned."
      allow_nil? true
      public? true
    end
  end

  identities do
    identity :name, [:name]
  end
end
