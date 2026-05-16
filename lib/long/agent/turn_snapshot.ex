defmodule Long.Agent.TurnSnapshot do
  @moduledoc """
  Per-session snapshot of the agent loop's in-flight state. One row per
  session (upsert by `session_id`). Written at every state-machine
  transition by `Long.Agent.Server` so a crashed/restarted process
  can resume the half-finished turn instead of starting over.

  Stored as JSON blobs because the values are ReqLLM-shaped Erlang
  terms that don't benefit from column-level queries:

    * `messages_json` — the full message list pushed into the LLM so
      far (system + history + current user + assistant + tool_results).
    * `pending_tool_calls_json` — tool_calls the LLM emitted but we
      haven't finished executing yet (used to figure out what to retry
      after a crash).
    * `tool_results_json` — completed tool results keyed by tool-call
      id, so a crash mid-batch only loses the in-flight ones.
  """

  use Ash.Resource,
    domain: Long.Agent,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "agent_turn_snapshots"
    repo Long.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      accept [
        :session_id,
        :turn,
        :stage,
        :messages_json,
        :pending_tool_calls_json,
        :tool_results_json,
        :last_assistant_text,
        :llm_alias
      ]

      upsert? true
      upsert_identity :session_id

      upsert_fields [
        :turn,
        :stage,
        :messages_json,
        :pending_tool_calls_json,
        :tool_results_json,
        :last_assistant_text,
        :llm_alias,
        :updated_at
      ]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :session_id, :string do
      allow_nil? false
      public? true
    end

    attribute :turn, :integer do
      default 0
      allow_nil? false
      public? true
    end

    attribute :stage, :atom do
      constraints one_of: [:idle, :calling_llm, :running_tools, :asked_user, :done]
      default :idle
      allow_nil? false
      public? true
    end

    attribute :messages_json, :string do
      description "JSON-encoded ReqLLM message list (system + conversation so far)."
      default "[]"
      public? true
    end

    attribute :pending_tool_calls_json, :string do
      description "JSON-encoded list of tool_calls the LLM emitted but we haven't finished executing yet."
      default "[]"
      public? true
    end

    attribute :tool_results_json, :string do
      description "JSON-encoded map of completed tool_results keyed by tool-call id."
      default "{}"
      public? true
    end

    attribute :last_assistant_text, :string do
      public? true
    end

    attribute :llm_alias, :string do
      public? true
    end

    timestamps()
  end

  identities do
    identity :session_id, [:session_id]
  end
end
