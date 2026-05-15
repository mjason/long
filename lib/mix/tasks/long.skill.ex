defmodule Mix.Tasks.Long.Skill do
  @moduledoc """
  Manage Agent Skills on disk. Skills are directories under
  `Application.get_env(:long, Long.Agent)[:skill_root]` (default
  `priv/agent/skills/`) containing a `SKILL.md` (YAML frontmatter +
  markdown body) and optional `scripts/`, `references/`, `assets/`
  subdirectories.

  The filesystem is the source of truth; `Long.Agent.Skill.Store`
  keeps an in-memory index in sync via a `file_system` watcher.

  ## Subcommands

      # List every skill currently in the index
      mix long.skill list

      # Force the Store to rescan skill_root (use after manual edits)
      mix long.skill reindex

      # Delete one skill directory from disk and refresh the index
      mix long.skill remove NAME
  """
  use Mix.Task

  @shortdoc "Manage Agent Skills (list / reindex / remove)"

  alias Long.Agent.Skill.Store

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    case argv do
      ["list" | _] -> do_list()
      ["reindex" | _] -> do_reindex()
      ["remove", name] -> do_remove(name)
      _ -> Mix.shell().info(@moduledoc)
    end
  end

  defp do_list do
    case Store.list_all() do
      [] ->
        Mix.shell().info("(no skills under #{Store.root()})")

      skills ->
        Enum.each(skills, fn s ->
          tags = if s.tags == [], do: "", else: " [#{Enum.join(s.tags, ",")}]"
          desc = if s.description, do: " — #{s.description}", else: ""
          Mix.shell().info("#{s.name}  (used #{s.use_count}×)  #{s.relative_path}#{tags}#{desc}")
        end)
    end
  end

  defp do_reindex do
    :ok = Store.reindex()
    skills = Store.list_all()
    Mix.shell().info("✓ reindexed #{Store.root()} — #{length(skills)} skill(s) loaded")
  end

  defp do_remove(name) do
    case Store.get(name) do
      {:ok, %{absolute_path: dir}} ->
        case File.rm_rf(dir) do
          {:ok, _} ->
            :ok = Store.reindex()
            Mix.shell().info("✓ removed #{name} (#{dir})")

          {:error, reason, _} ->
            Mix.shell().error("✗ delete failed: #{:file.format_error(reason)}")
        end

      {:error, :not_found} ->
        Mix.shell().error("✗ no such skill: #{name}")
    end
  end
end
