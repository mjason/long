defmodule Mix.Tasks.Long.Skill do
  @moduledoc """
  Manage L3 skill index entries from the command line.

  All files must live under the configured `memory_root`
  (`config :long, Long.Agent, memory_root: …`); the CLI never copies files,
  it just records pointers. Move/copy files yourself first if they're
  elsewhere.

  ## Subcommands

      # Register one file (auto-detects kind from extension, looks for
      # `*_sop.md` next to a .py to fill sop_path)
      mix long.skill register PATH [--name NAME] [--description "..."] [--tags a,b,c] [--sop SOP_PATH]

      # Walk a directory and register every .py / *_sop.md (pairs them)
      mix long.skill scan [DIR]

      # Print every registered skill
      mix long.skill list [--kind script_py|sop_md|template_py|other]

      # Remove one skill row
      mix long.skill remove NAME
  """
  use Mix.Task

  @shortdoc "Manage L3 skill index entries (register/scan/list/remove)"

  @switches [
    name: :string,
    description: :string,
    tags: :string,
    sop: :string,
    kind: :string
  ]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    case argv do
      ["register" | rest] -> register(rest)
      ["scan" | rest] -> scan(rest)
      ["list" | rest] -> list(rest)
      ["remove", name] -> remove(name)
      _ -> Mix.shell().info(@moduledoc)
    end
  end

  defp register([]), do: Mix.shell().error("register: missing PATH")

  defp register([path | rest]) do
    {opts, _, _} = OptionParser.parse(rest, switches: @switches)

    case do_register(path, opts) do
      {:ok, skill} -> Mix.shell().info(format_registered(skill))
      {:error, msg} -> Mix.shell().error("✗ #{msg}")
    end
  end

  defp scan([dir]), do: scan_dir(dir)
  defp scan([]), do: scan_dir(memory_root())

  defp scan_dir(dir) do
    abs_dir = Path.expand(dir)
    root = memory_root()

    cond do
      not File.dir?(abs_dir) ->
        Mix.shell().error("✗ not a directory: #{abs_dir}")

      not under?(abs_dir, root) ->
        Mix.shell().error("✗ #{abs_dir} is outside memory_root #{root}")

      true ->
        files =
          abs_dir
          |> Path.join("**/*.{py,md}")
          |> Path.wildcard()
          |> Enum.sort()

        {pys, mds} = Enum.split_with(files, &(Path.extname(&1) == ".py"))
        sop_map = Map.new(mds, &{Path.basename(&1), &1})

        {registered, errors} =
          Enum.reduce(pys ++ mds, {[], []}, fn path, {ok, errs} ->
            opts = inferred_opts(path, sop_map, pys)

            case do_register(path, opts) do
              {:ok, s} -> {[s | ok], errs}
              {:error, e} -> {ok, [{path, e} | errs]}
            end
          end)

        Mix.shell().info("✓ registered/updated #{length(registered)} skill(s) under #{abs_dir}")

        Enum.each(errors, fn {p, e} -> Mix.shell().error("  ✗ #{p}: #{e}") end)
    end
  end

  defp list(argv) do
    {opts, _, _} = OptionParser.parse(argv, switches: [kind: :string])

    {:ok, skills} = Long.Agent.list_skills()

    skills =
      case opts[:kind] do
        nil -> skills
        k -> Enum.filter(skills, &(&1.kind == String.to_atom(k)))
      end

    if skills == [] do
      Mix.shell().info("(no skills registered)")
    else
      Enum.each(skills, fn s ->
        sop = if s.sop_path, do: " ↔ #{s.sop_path}", else: ""
        tags = if s.tags == [], do: "", else: " [#{Enum.join(s.tags, ",")}]"

        Mix.shell().info(
          "#{s.name}  (#{s.kind}, used #{s.use_count}×)  #{s.relative_path}#{sop}#{tags}"
        )
      end)
    end
  end

  defp remove(name) do
    case Long.Agent.get_skill(name) do
      {:ok, skill} ->
        case Ash.destroy(skill) do
          :ok -> Mix.shell().info("✓ removed #{name}")
          {:ok, _} -> Mix.shell().info("✓ removed #{name}")
          {:error, e} -> Mix.shell().error("✗ destroy failed: #{inspect(e)}")
        end

      _ ->
        Mix.shell().error("✗ no such skill: #{name}")
    end
  end

  # ── core registration ────────────────────────────────────────────────────

  defp do_register(path, opts) do
    abs = Path.expand(path)
    root = memory_root()

    cond do
      not File.exists?(abs) ->
        {:error, "file not found: #{abs}"}

      not under?(abs, root) ->
        {:error, "file must live under memory_root #{root}; got #{abs}"}

      true ->
        rel = Path.relative_to(abs, root)
        kind = opts[:kind] |> parse_kind() || detect_kind(abs)
        name = opts[:name] || derive_name(rel)
        sop_path = opts[:sop] |> resolve_sop(abs, root)
        tags = parse_tags(opts[:tags])
        description = opts[:description] || ""

        Long.Agent.register_skill(%{
          name: name,
          kind: kind,
          relative_path: rel,
          sop_path: sop_path,
          description: description,
          tags: tags
        })
    end
  end

  defp parse_kind(nil), do: nil

  defp parse_kind(k) when is_binary(k) do
    case k do
      "script_py" -> :script_py
      "sop_md" -> :sop_md
      "template_py" -> :template_py
      "other" -> :other
      _ -> nil
    end
  end

  defp detect_kind(path) do
    base = Path.basename(path)

    cond do
      String.ends_with?(base, ".template.py") -> :template_py
      String.ends_with?(base, ".py") -> :script_py
      String.ends_with?(base, ".md") -> :sop_md
      true -> :other
    end
  end

  defp derive_name(rel) do
    rel
    |> Path.rootname()
    |> Path.basename()
    |> String.replace("_sop", "")
  end

  defp resolve_sop(nil, abs, root) do
    candidate = Path.rootname(abs) <> "_sop.md"
    if File.exists?(candidate), do: Path.relative_to(candidate, root), else: nil
  end

  defp resolve_sop(rel, _abs, root) do
    full = Path.expand(rel, root)
    if File.exists?(full), do: Path.relative_to(full, root), else: rel
  end

  defp parse_tags(nil), do: []

  defp parse_tags(s) when is_binary(s) do
    s |> String.split(~r/[,;\s]+/, trim: true) |> Enum.reject(&(&1 == ""))
  end

  defp inferred_opts(path, sop_map, py_paths) do
    base = Path.basename(path)

    cond do
      Path.extname(path) == ".py" ->
        sop_name = Path.basename(base, ".py") <> "_sop.md"
        sop = if Map.has_key?(sop_map, sop_name), do: sop_map[sop_name], else: nil
        [sop: sop]

      String.ends_with?(base, "_sop.md") ->
        # If a sibling .py exists, registering this as standalone would
        # collide on name with the script entry — skip duplicates.
        sibling = Path.basename(base, "_sop.md") <> ".py"
        sibling_full = Path.join(Path.dirname(path), sibling)

        if sibling_full in py_paths do
          [skip: true]
        else
          []
        end

      true ->
        []
    end
  end

  # ── path helpers ─────────────────────────────────────────────────────────

  defp memory_root do
    case Application.get_env(:long, Long.Agent, [])[:memory_root] do
      nil -> Path.expand("priv/agent/memory", File.cwd!())
      p -> Path.expand(p)
    end
  end

  defp under?(path, root) do
    rel = Path.relative_to(path, root)
    not (String.starts_with?(rel, "..") or rel == path)
  end

  defp format_registered(s) do
    sop = if s.sop_path, do: " (sop: #{s.sop_path})", else: ""
    "✓ registered #{s.name} :: #{s.kind} :: #{s.relative_path}#{sop}"
  end
end
