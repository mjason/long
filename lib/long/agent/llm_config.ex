defmodule Long.Agent.LLMConfig do
  @moduledoc """
  Replacement for GenericAgent's `mykey.py` — one row per LLM endpoint/alias.

  Two ways to provide the API key:

  - `:api_key` — paste it directly. Marked sensitive so Ash redacts it in
    logs/errors. Convenient for single-machine setups.
  - `:api_key_env_var` — name of an env var holding the key (12-factor
    style). Use this when you don't want the secret in SQLite, e.g. shared
    DB files or deployment via env vars.

  `api_key_env_var` takes precedence if both are set — lets you override
  the DB value from the environment without editing the row.

  For `kind: :mixin`, `params["members"]` holds an ordered list of other
  aliases to round-robin/route through (mirrors `llmcore.MixinSession`).
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "agent_llm_configs"
    repo Long.Repo
  end

  @mutable_fields [
    :kind,
    :model,
    :api_base,
    :api_key,
    :api_key_env_var,
    :params,
    :enabled,
    :sort_order
  ]

  actions do
    defaults [:read, :destroy]

    create :register do
      accept [:alias | @mutable_fields]
      upsert? true
      upsert_identity :alias
      upsert_fields @mutable_fields ++ [:updated_at]
    end

    update :update do
      accept @mutable_fields
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :alias, :string do
      description "Stable identifier referenced from sessions, e.g. \"claude_main\", \"kimi_fast\"."
      allow_nil? false
      public? true
    end

    attribute :kind, :atom do
      constraints one_of: [:claude, :openai, :native_claude, :native_openai, :mixin]
      allow_nil? false
      public? true
    end

    attribute :model, :string do
      public? true
    end

    attribute :api_base, :string do
      public? true
    end

    attribute :api_key, :string do
      description "Raw API key. Sensitive — redacted in logs. Leave blank to use api_key_env_var instead."
      sensitive? true
      public? true
    end

    attribute :api_key_env_var, :string do
      description "Name of an env var that holds the key (12-factor style). Takes precedence over api_key when set."
      public? true
    end

    attribute :params, :map do
      description "Free-form provider-specific overrides (temperature, max_tokens, headers, mixin members, …)."
      default %{}
      public? true
    end

    attribute :enabled, :boolean do
      default true
      allow_nil? false
      public? true
    end

    attribute :sort_order, :integer do
      default 0
      allow_nil? false
      public? true
    end

    timestamps()
  end

  identities do
    identity :alias, [:alias]
  end
end
