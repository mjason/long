defmodule Long.Repo.Migrations.AddSkillBodyDropKind do
  @moduledoc """
  Migrate the L3 skill index to the Anthropic-Skills-compatible shape:
  drop `kind` and `sop_path` (no longer meaningful — every skill is a
  SKILL.md directory) and add `body` (the markdown content) +
  `frontmatter` (the parsed YAML header).
  """

  use Ecto.Migration

  def up do
    alter table(:agent_skills) do
      remove :sop_path
      remove :kind
      add :body, :text
      add :frontmatter, :map, default: %{}
    end
  end

  def down do
    alter table(:agent_skills) do
      remove :frontmatter
      remove :body
      add :kind, :text, null: false
      add :sop_path, :text
    end
  end
end
