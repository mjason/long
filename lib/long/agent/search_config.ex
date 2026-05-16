defmodule Long.Agent.SearchConfig do
  @moduledoc """
  One row per configured search provider. Mirrors `LLMConfig`'s shape so
  the operator UX is consistent (paste API key directly, or reference an
  env var by name).

  Two providers supported today:

    * `:tavily` — https://api.tavily.com/search (POST, key in body)
    * `:brave_api` — https://api.search.brave.com/res/v1/web/search
      (GET, key in `X-Subscription-Token` header). Distinct from the
      SERP-scrape Brave parser; this is the official, paid (but free
      tier 2k/mo) API.

  The aggregator (`Long.Agent.Search`) loads every `enabled: true` row
  at search time. When at least one row exists, it uses *only* configured
  providers (skipping the unreliable SERP scrapers). When none exist,
  the search falls back to the legacy 3-engine SERP scrape so dev/test
  environments keep working without API keys.
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "agent_search_configs"
    repo Long.Repo
  end

  @providers ~w(tavily brave_api)

  @doc "Provider names accepted by the schema. Mirrors the `one_of` constraint on `:provider` so UI pickers don't drift."
  def providers, do: @providers

  @mutable_fields [
    :provider,
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
      description "Stable name, e.g. \"tavily-main\", \"brave-paid\". Used in logs and admin UI."
      allow_nil? false
      public? true
    end

    attribute :provider, :atom do
      constraints one_of: [:tavily, :brave_api]
      allow_nil? false
      public? true
    end

    attribute :api_key, :string do
      description "Raw API key. Sensitive — redacted in logs. Leave blank to use api_key_env_var instead."
      sensitive? true
      public? true
    end

    attribute :api_key_env_var, :string do
      description "Name of env var holding the key (12-factor). Takes precedence over api_key when set."
      public? true
    end

    attribute :params, :map do
      description "Provider-specific overrides (Tavily search_depth, per-call limit caps, …)."
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
