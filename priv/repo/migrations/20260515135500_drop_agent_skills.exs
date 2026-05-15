defmodule Long.Repo.Migrations.DropAgentSkills do
  @moduledoc """
  Drop the `agent_skills` table. The L3 skill index is now an
  in-memory `Long.Agent.Skill.Store` backed by the filesystem at
  `skill_root` — the database is no longer the source of truth.
  """

  use Ecto.Migration

  def up do
    drop table(:agent_skills)
  end

  def down do
    create table(:agent_skills, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :text, null: false
      add :relative_path, :text, null: false
      add :description, :text
      add :body, :text
      add :frontmatter, :map, default: %{}
      add :tags, {:array, :text}, default: []
      add :last_used_at, :utc_datetime
      add :use_count, :integer, default: 0
      timestamps()
    end

    create unique_index(:agent_skills, [:name])
  end
end
