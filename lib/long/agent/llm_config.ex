defmodule Long.Agent.LLMConfig do
  @moduledoc """
  Replacement for GenericAgent's `mykey.py` — one row per LLM endpoint/alias.

  API keys are **never** stored in the DB. Each row points to an environment
  variable name (`api_key_env_var`), and the runtime (`Long.Agent.LLM.*`,
  Phase 1) reads the actual secret from `System.get_env/1`.

  For `kind: :mixin`, `params["members"]` holds an ordered list of other aliases
  to round-robin/route through (mirrors `llmcore.MixinSession`).
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "agent_llm_configs"
    repo Long.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :register do
      accept [:alias, :kind, :model, :api_base, :api_key_env_var, :params, :enabled, :sort_order]
      upsert? true
      upsert_identity :alias

      upsert_fields [
        :kind,
        :model,
        :api_base,
        :api_key_env_var,
        :params,
        :enabled,
        :sort_order,
        :updated_at
      ]
    end

    update :update do
      accept [:kind, :model, :api_base, :api_key_env_var, :params, :enabled, :sort_order]
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

    attribute :api_key_env_var, :string do
      description "Name of the env var that holds the secret. We never store the key itself."
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
