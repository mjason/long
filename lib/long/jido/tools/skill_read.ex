defmodule Long.Jido.Tools.SkillRead do
  @moduledoc """
  Tier-L2 of skill progressive disclosure: return the full SKILL.md
  body for a named skill, plus the absolute `resources_dir` where its
  companion files (`scripts/`, `references/`, `assets/`) live. Run
  those scripts yourself via `code_run` — this tool does **not**
  execute anything.
  """

  use Jido.Action,
    name: "skill_read",
    description:
      "Fetch a skill's full SKILL.md instructions by exact name. Also " <>
        "returns `resources_dir` (absolute path to the skill folder) so " <>
        "you can invoke its `scripts/*.py` etc. through `code_run`. " <>
        "Use `skill_search` first if you don't know the exact name.",
    category: "skill",
    tags: ["skill", "read"],
    vsn: "2.0.0",
    schema:
      Zoi.object(%{
        name: Zoi.string(description: "Skill name as listed in the system prompt")
      })

  alias Long.Agent.Skill.Store

  @impl true
  def run(params, _ctx) do
    name = (params[:name] || params["name"] || "") |> to_string() |> String.trim()

    if name == "" do
      {:ok, %{status: "error", msg: "name is required"}}
    else
      case Store.get(name) do
        {:ok, skill} ->
          _ = Store.touch(skill.name)

          {:ok,
           %{
             status: "success",
             name: skill.name,
             description: skill.description,
             tags: skill.tags,
             frontmatter: skill.frontmatter,
             body: skill.body || "",
             resources_dir: skill.absolute_path
           }}

        {:error, :not_found} ->
          {:ok, %{status: "error", msg: "skill not found: #{name}"}}
      end
    end
  end
end
