defmodule Long.Repo.Migrations.GroupRename do
  @moduledoc """
  Rename the Household concept to the more general Group:

    * table `agent_households`        -> `agent_groups`
    * table `agent_household_members` -> `agent_members`
    * member FK column `household_id` -> `group_id`

  SQLite (>= 3.25) automatically rewrites foreign keys that reference a
  renamed table, so the member/credential/bot_user FKs follow along and no
  data is lost. Also neutralizes the old kinship `MemberRelation` values
  (spouse/child/parent) down to `other` — relation is now just self/other.
  """

  use Ecto.Migration

  def up do
    rename table(:agent_households), to: table(:agent_groups)
    rename table(:agent_household_members), to: table(:agent_members)
    rename table(:agent_members), :household_id, to: :group_id

    execute(
      "UPDATE agent_members SET relation = 'other' WHERE relation IN ('spouse', 'child', 'parent')"
    )
  end

  def down do
    rename table(:agent_members), :group_id, to: :household_id
    rename table(:agent_members), to: table(:agent_household_members)
    rename table(:agent_groups), to: table(:agent_households)
  end
end
