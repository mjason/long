defmodule Long.Agent.Skill.StoreTest do
  use ExUnit.Case, async: false

  alias Long.Agent.Skill.Store

  setup do
    tmp = Path.join(System.tmp_dir!(), "long-skill-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    original = Application.get_env(:long, Long.Agent, [])
    Application.put_env(:long, Long.Agent, Keyword.put(original, :skill_root, tmp))
    :ok = Store.reindex()

    on_exit(fn ->
      Application.put_env(:long, Long.Agent, original)
      File.rm_rf!(tmp)
      _ = Store.reindex()
    end)

    {:ok, tmp: tmp}
  end

  describe "boot scan" do
    test "loads every SKILL.md under skill_root", %{tmp: tmp} do
      write_skill(tmp, "alpha", "first")
      write_skill(tmp, "beta", "second")

      :ok = Store.reindex()

      names = Enum.map(Store.list_all(), & &1.name)
      assert "alpha" in names
      assert "beta" in names
    end

    test "ignores files missing required frontmatter", %{tmp: tmp} do
      write_skill(tmp, "valid", "with description")

      bad = Path.join(tmp, "broken")
      File.mkdir_p!(bad)
      File.write!(Path.join(bad, "SKILL.md"), "---\nname: broken\n---\n\nno description\n")

      :ok = Store.reindex()

      names = Enum.map(Store.list_all(), & &1.name)
      assert "valid" in names
      refute "broken" in names
    end
  end

  describe "list_names_for_prompt/0" do
    test "empty when no skills exist" do
      :ok = Store.reindex()
      assert Store.list_names_for_prompt() == ""
    end

    test "lists names alphabetically", %{tmp: tmp} do
      write_skill(tmp, "zeta", "z")
      write_skill(tmp, "alpha", "a")
      :ok = Store.reindex()

      out = Store.list_names_for_prompt()
      assert out =~ "Available skills"
      assert :binary.match(out, "alpha") |> elem(0) < :binary.match(out, "zeta") |> elem(0)
    end
  end

  describe "search/2" do
    test "ranks by name > tag > description > body", %{tmp: tmp} do
      write_skill(tmp, "fetch_weather", "pull current weather", ["weather", "api"])
      write_skill(tmp, "render_chart", "render a chart", ["viz"])
      :ok = Store.reindex()

      [first | _] = Store.search("weather forecast", limit: 5)
      assert first.row.name == "fetch_weather"
    end

    test "empty query returns nothing", %{tmp: tmp} do
      write_skill(tmp, "anything", "anything")
      :ok = Store.reindex()
      assert Store.search("", limit: 5) == []
    end
  end

  describe "touch/1 + .usage.json" do
    test "increments use_count and persists to disk", %{tmp: tmp} do
      write_skill(tmp, "tracked", "trackable skill")
      :ok = Store.reindex()

      :ok = Store.touch("tracked")
      :ok = Store.touch("tracked")

      {:ok, skill} = Store.get("tracked")
      assert skill.use_count == 2
      assert skill.last_used_at != nil

      usage_path = Path.join([tmp, "tracked", ".usage.json"])
      assert File.exists?(usage_path)
      decoded = Jason.decode!(File.read!(usage_path))
      assert decoded["use_count"] == 2
      assert is_binary(decoded["last_used_at"])
    end

    test "usage survives a reindex", %{tmp: tmp} do
      write_skill(tmp, "persistent", "persists across rescan")
      :ok = Store.reindex()
      :ok = Store.touch("persistent")

      :ok = Store.reindex()
      {:ok, skill} = Store.get("persistent")
      assert skill.use_count == 1
    end

    test "touch on unknown skill returns error" do
      assert {:error, :not_found} = Store.touch("ghost-#{System.unique_integer([:positive])}")
    end
  end

  describe "reindex/0" do
    test "picks up new skills", %{tmp: tmp} do
      :ok = Store.reindex()
      assert Store.list_all() == []

      write_skill(tmp, "late_arrival", "showed up after boot")
      :ok = Store.reindex()

      {:ok, _} = Store.get("late_arrival")
    end

    test "drops skills whose SKILL.md was deleted", %{tmp: tmp} do
      write_skill(tmp, "soon_gone", "will vanish")
      :ok = Store.reindex()
      {:ok, _} = Store.get("soon_gone")

      File.rm_rf!(Path.join(tmp, "soon_gone"))
      :ok = Store.reindex()

      assert {:error, :not_found} = Store.get("soon_gone")
    end
  end

  defp write_skill(root, name, description, tags \\ []) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)

    tag_yaml =
      if tags == [], do: "", else: "\ntags: [#{Enum.join(tags, ", ")}]"

    contents = """
    ---
    name: #{name}
    description: #{description}#{tag_yaml}
    ---

    # #{name}

    body text
    """

    File.write!(Path.join(dir, "SKILL.md"), contents)
  end
end
