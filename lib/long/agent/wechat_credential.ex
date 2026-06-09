defmodule Long.Agent.WechatCredential do
  @moduledoc """
  Stored iLink bot credentials and long-poll cursor for the WeChat
  adapter. One row per hosted WeChat account (identity on `:name`,
  default `"default"`). Multiple rows are supported so a household can
  connect several accounts, each `member_id`-bound to a different role;
  `Long.Agent.Bots.Wechat.Manager` runs one worker per row.

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

    references do
      reference :member, on_delete: :nilify
    end
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      upsert? true
      upsert_identity :name
      accept [:name, :bot_token, :ilink_bot_id, :updates_buf, :member_id, :locale]
    end

    update :update_buf do
      accept [:updates_buf]
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

    attribute :locale, :string do
      description "Language for this account's outbound copy (e.g. \"zh\"), overriding member/household. Nil = inherit."
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :member, Long.Agent.HouseholdMember do
      description "The household member (role) this hosted WeChat account serves, if assigned."
      allow_nil? true
      public? true
    end
  end

  identities do
    identity :name, [:name]
  end
end
