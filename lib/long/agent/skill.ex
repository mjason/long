defmodule Long.Agent.Skill do
  @moduledoc """
  L3 skill index. The skill *body* (Python script, SOP markdown, template, …)
  remains on disk under the configured memory root — user decision: keep Python
  execution, Elixir is only the orchestrator. This resource stores discoverable
  metadata (name, path, description, last-used) so the agent can search/rank
  skills without reading the filesystem on every turn.
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "agent_skills"
    repo Long.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :register do
      accept [:name, :kind, :relative_path, :sop_path, :description, :tags]
      upsert? true
      upsert_identity :name
      upsert_fields [:kind, :relative_path, :sop_path, :description, :tags, :updated_at]
    end

    update :update do
      accept [:kind, :relative_path, :sop_path, :description, :tags]
    end

    update :touch do
      require_atomic? false

      change atomic_update(:use_count, expr(use_count + 1))
      change set_attribute(:last_used_at, &DateTime.utc_now/0)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :kind, :atom do
      constraints one_of: [:script_py, :sop_md, :template_py, :other]
      default :script_py
      allow_nil? false
      public? true
    end

    attribute :relative_path, :string do
      description "Path relative to the memory root, e.g. \"ljqCtrl.py\" or \"autonomous_operation_sop/helper.py\"."
      allow_nil? false
      public? true
    end

    attribute :sop_path, :string do
      description "Companion `*_sop.md` describing how to use this skill."
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :tags, {:array, :string} do
      default []
      public? true
    end

    attribute :last_used_at, :utc_datetime do
      public? true
    end

    attribute :use_count, :integer do
      default 0
      allow_nil? false
      public? true
    end

    timestamps()
  end

  identities do
    identity :name, [:name]
  end
end
