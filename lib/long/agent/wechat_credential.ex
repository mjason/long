defmodule Long.Agent.WechatCredential do
  @moduledoc """
  Stored iLink bot credentials and long-poll cursor for the WeChat
  adapter. Single-row by default (identity on `:name`, default
  `"default"`), but the schema supports multiple named bots so a
  future "switch between accounts" UX has somewhere to land.

  Populated by `mix long.wechat.login` after QR confirmation; read on
  every poll cycle by `Long.Agent.Bots.Wechat.Worker`. The
  `updates_buf` cursor is rewritten in place after each `getupdates`
  call so a crash doesn't replay old messages.
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "agent_wechat_credentials"
    repo Long.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      upsert? true
      upsert_identity :name
      accept [:name, :bot_token, :ilink_bot_id, :updates_buf]
    end

    update :update_buf do
      accept [:updates_buf]
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
      description "iLink bot_token returned by QR login. Sensitive — redacted in logs."
      sensitive? true
      public? true
    end

    attribute :ilink_bot_id, :string do
      description "Stable bot identity from iLink (returned with bot_token at login time)."
      public? true
    end

    attribute :updates_buf, :string do
      description "Long-poll cursor for getupdates. Rewritten after each successful poll."
      default ""
      public? true
    end

    timestamps()
  end

  identities do
    identity :name, [:name]
  end
end
