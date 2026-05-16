defmodule Long.Repo.Migrations.DropLlmSortOrder do
  @moduledoc """
  `sort_order` on `agent_llm_configs` was never consumed at runtime
  (LLMCall routes by `alias`; `default: true` already marks the
  fallback). Drop it.
  """

  use Ecto.Migration

  def up do
    alter table(:agent_llm_configs) do
      remove :sort_order
    end
  end

  def down do
    alter table(:agent_llm_configs) do
      add :sort_order, :bigint, null: false, default: 0
    end
  end
end
