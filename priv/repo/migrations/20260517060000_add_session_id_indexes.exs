defmodule Long.Repo.Migrations.AddSessionIdIndexes do
  @moduledoc """
  Add covering indexes for the two read paths hit on every turn:

    - `agent_messages` is scanned by `History.load_or_compress/2` on
      every turn (and by AshGraphql's `messagesForSession`). The
      composite `(session_id, inserted_at)` covers both the WHERE and
      the ORDER BY.
    - `agent_scheduled_tasks` is queried by `scheduledTasksForSession`
      (sort `next_run_at: :asc`) and by `SchedulerTick` (full table
      scan filtering `enabled = true`). The composite
      `(session_id, next_run_at)` covers the GraphQL path; SchedulerTick
      keeps its full-table scan but it's a tiny table.

  Without these, message tables of ~10K+ rows turn every turn's
  history load into a sequential scan + filesort.
  """
  use Ecto.Migration

  def up do
    create_if_not_exists index(:agent_messages, [:session_id, :inserted_at])
    create_if_not_exists index(:agent_scheduled_tasks, [:session_id, :next_run_at])
  end

  def down do
    drop_if_exists index(:agent_messages, [:session_id, :inserted_at])
    drop_if_exists index(:agent_scheduled_tasks, [:session_id, :next_run_at])
  end
end
