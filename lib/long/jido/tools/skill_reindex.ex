defmodule Long.Jido.Tools.SkillReindex do
  @moduledoc """
  Force the skill Store to rescan `skill_root`. Call this after writing
  a new SKILL.md / scripts via `file_write`, in case the filesystem
  watcher missed the event (WSL, NFS, large bursts). On well-behaved
  filesystems the Store reloads automatically within 250 ms.
  """

  use Jido.Action,
    name: "skill_reindex",
    description:
      "Rescan the skills directory and rebuild the in-memory index. Use " <>
        "after `file_write`-installing a new SKILL.md to make sure the " <>
        "skill becomes visible right away.",
    category: "skill",
    tags: ["skill", "admin"],
    vsn: "1.0.0",
    schema: Zoi.object(%{})

  alias Long.Agent.Skill.Store

  @impl true
  def run(_params, _ctx) do
    :ok = Store.reindex()

    skills = Store.list_all()
    {:ok, %{status: "success", root: Store.root(), count: length(skills), names: Enum.map(skills, & &1.name)}}
  end
end
