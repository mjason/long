defmodule Long.Agent.Secret do
  @moduledoc """
  Flat key/value store for credentials the agent needs at tool-call
  time — API tokens, cookie strings, signed URLs, anything the user
  doesn't want pasted into chat messages or memory.

  Distinct from `GlobalMemory` / `SessionMemory`: memory is part of the
  reasoning context (auto-surfaced into prompts, summarised, recalled),
  while secrets are explicitly *not* surfaced — the agent has to ask
  GraphQL for one when it needs it, then pass the value straight to
  a tool (e.g. `http_fetch` Authorization header) without echoing it
  back to the user.

  Identity: `name` (unique). Schema is intentionally minimal — `name`,
  `value`, optional `description` so the agent knows what it's for.

  At-rest encryption is deliberately omitted (LAN-only deployment, see
  v0.2.3 history). `value` is marked `sensitive? true` so Ash redacts
  it in logs / `inspect` output; the GraphQL field is still readable
  because the whole point is that the agent can fetch it.
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshGraphql.Resource]

  sqlite do
    table "agent_secrets"
    repo Long.Repo
  end

  graphql do
    type :secret

    queries do
      list :secrets, :read
      get :secret, :read
    end

    mutations do
      create :put_secret, :upsert
      update :update_secret, :update
      destroy :destroy_secret, :destroy
    end
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
      pagination keyset?: true, default_limit: 50, max_page_size: 200, required?: false
    end

    create :upsert do
      accept [:name, :value, :description]
      upsert? true
      upsert_identity :name
      upsert_fields [:value, :description, :updated_at]
    end

    update :update do
      accept [:value, :description]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      description "Stable identifier the agent passes around, e.g. \"github_personal\", \"openai_user\". Lowercase + underscores recommended so it survives JSON / URL contexts."
      allow_nil? false
      public? true
    end

    attribute :value, :string do
      description "The actual secret. Stored plaintext (LAN-only deployment); marked sensitive so it's redacted in logs."
      sensitive? true
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      description "Free-form note for the agent — what this is for, which API it unlocks, expiry hints. Helps the agent pick the right secret when multiple exist."
      public? true
    end

    timestamps()
  end

  identities do
    identity :name, [:name]
  end
end
