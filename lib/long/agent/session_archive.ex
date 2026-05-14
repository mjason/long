defmodule Long.Agent.SessionArchive do
  @moduledoc """
  L4 session archive: a compressed/summarized snapshot of a finished session
  kept for long-term recall. Triggered by the `start_long_term_update` tool or
  by the Oban archive worker (Phase 5).
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "agent_session_archives"
    repo Long.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:original_session_id, :title, :summary, :insights, :payload, :archived_at]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :original_session_id, :uuid do
      description "Session this archive was produced from. Nullable so deleting the source session does not orphan the archive."
      public? true
    end

    attribute :title, :string do
      public? true
    end

    attribute :summary, :string do
      public? true
    end

    attribute :insights, :string do
      public? true
    end

    attribute :payload, :map do
      description "Full session dump (messages, checkpoints) for replay/audit."
      public? true
    end

    attribute :archived_at, :utc_datetime do
      default &DateTime.utc_now/0
      allow_nil? false
      public? true
    end

    timestamps()
  end
end
