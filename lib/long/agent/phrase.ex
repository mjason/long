defmodule Long.Agent.Phrase do
  @moduledoc """
  Operator override for one piece of bot/system copy, keyed by
  `(key, locale)`. The built-in defaults live in `Long.Copy`; a row here
  overrides the default for that key + locale, editable from
  `/manage → Phrases`. Empty/absent → the built-in default is used.
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "agent_phrases"
    repo Long.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      upsert? true
      upsert_identity :key_locale
      accept [:key, :locale, :text]
    end

    update :update do
      accept [:text]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      description "Catalog key, e.g. \"bots.cleared\"."
      allow_nil? false
      public? true
    end

    attribute :locale, :string do
      description "BCP-47-ish locale, e.g. \"en\" or \"zh\"."
      allow_nil? false
      public? true
    end

    attribute :text, :string do
      description "Override text. Supports %{name} placeholders matching the built-in default."
      public? true
    end

    timestamps()
  end

  identities do
    identity :key_locale, [:key, :locale]
  end
end
