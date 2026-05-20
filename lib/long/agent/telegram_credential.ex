defmodule Long.Agent.TelegramCredential do
  @moduledoc """
  Stored Telegram bot credentials, read by `Long.Agent.Bots.Telegram`
  at boot and on `:reload`. Single-row by default (identity on `:name`,
  default `"default"`); schema supports multiple named bots for a
  future "manage several bots" UX but the worker only consults the
  default row today.

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
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      upsert? true
      upsert_identity :name
      accept [:name, :bot_token, :username, :enabled]
    end

    update :update do
      accept [:bot_token, :username, :enabled]
    end

    update :update_username do
      accept [:username]
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

    timestamps()
  end

  identities do
    identity :name, [:name]
  end
end
