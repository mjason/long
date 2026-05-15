defmodule Long.Repo.Migrations.AddErrorTracker do
  use Ecto.Migration

  def up, do: ErrorTracker.Migration.up(version: 5)

  # Drop all error_tracker migrations on rollback regardless of which
  # version was last applied.
  def down, do: ErrorTracker.Migration.down(version: 1)
end
