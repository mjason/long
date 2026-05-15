defmodule Long.Jido.SkillToolsTest do
  use ExUnit.Case, async: false

  alias Long.Agent.Skill.Store
  alias Long.Jido.Tools.{SkillRead, SkillReindex, SkillSearch}

  setup do
    tmp = Path.join(System.tmp_dir!(), "long-skill-tools-#{System.unique_integer([:positive])}")
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

  describe "SkillSearch" do
    test "ranks skills with full description payload", %{tmp: tmp} do
      write_skill(tmp, "translate_text", %{
        description: "translate text between languages",
        tags: ["nlp", "translate"]
      })

      write_skill(tmp, "fetch_stock_quote", %{
        description: "get a stock quote",
        tags: ["finance"]
      })

      Store.reindex()

      assert {:ok, %{status: "success", query: "translate language", results: [first | _]}} =
               Jido.Exec.run(SkillSearch, %{query: "translate language"}, %{})

      assert first.name == "translate_text"
      assert first.description =~ "translate"
      refute Map.has_key?(first, :body)
    end

    test "rejects empty query" do
      assert {:ok, %{status: "error", msg: msg}} =
               Jido.Exec.run(SkillSearch, %{query: "   "}, %{})

      assert msg =~ "empty"
    end

    test "limit caps the result count", %{tmp: tmp} do
      for n <- 1..5 do
        write_skill(tmp, "lim_#{n}", %{description: "limiting_keyword #{n}"})
      end

      Store.reindex()

      assert {:ok, %{results: results}} =
               Jido.Exec.run(SkillSearch, %{query: "limiting_keyword", limit: 2}, %{})

      assert length(results) == 2
    end
  end

  describe "SkillRead" do
    test "returns body, frontmatter, and absolute resources_dir", %{tmp: tmp} do
      body = "# How to use\n\nRun `scripts/foo.py <path>`."

      write_skill(
        tmp,
        "pdf_extract",
        %{description: "extract text from PDF", tags: ["pdf"], license: "MIT"},
        body
      )

      Store.reindex()

      assert {:ok, payload} = Jido.Exec.run(SkillRead, %{name: "pdf_extract"}, %{})
      assert payload.status == "success"
      assert payload.body == body
      assert payload.frontmatter["license"] == "MIT"
      assert payload.resources_dir == Path.join(tmp, "pdf_extract")
    end

    test "bumps use_count + persists .usage.json after a read", %{tmp: tmp} do
      write_skill(tmp, "noop", %{description: "no-op"})
      Store.reindex()

      assert {:ok, %{status: "success"}} = Jido.Exec.run(SkillRead, %{name: "noop"}, %{})

      {:ok, fresh} = Store.get("noop")
      assert fresh.use_count == 1
      assert fresh.last_used_at != nil

      usage_path = Path.join([tmp, "noop", ".usage.json"])
      assert File.exists?(usage_path)
      assert Jason.decode!(File.read!(usage_path))["use_count"] == 1
    end

    test "unknown skill returns error" do
      assert {:ok, %{status: "error", msg: msg}} =
               Jido.Exec.run(SkillRead, %{name: "unknown-skill-9999"}, %{})

      assert msg =~ "not found"
    end

    test "empty name returns error" do
      assert {:ok, %{status: "error", msg: msg}} =
               Jido.Exec.run(SkillRead, %{name: ""}, %{})

      assert msg =~ "required"
    end
  end

  describe "SkillReindex" do
    test "picks up a newly written SKILL.md", %{tmp: tmp} do
      assert {:ok, %{count: 0}} = Jido.Exec.run(SkillReindex, %{}, %{})

      write_skill(tmp, "fresh", %{description: "freshly installed skill"})

      assert {:ok, %{status: "success", count: 1, names: ["fresh"]}} =
               Jido.Exec.run(SkillReindex, %{}, %{})
    end
  end

  defp write_skill(root, name, frontmatter, body \\ "# body\n\nhi") do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)

    fm = Map.put_new(frontmatter, :name, name)

    yaml =
      fm
      |> Enum.map(fn {k, v} -> "#{k}: #{yaml_value(v)}" end)
      |> Enum.join("\n")

    contents = "---\n#{yaml}\n---\n\n#{body}"
    File.write!(Path.join(dir, "SKILL.md"), contents)
  end

  defp yaml_value(list) when is_list(list), do: "[#{Enum.join(list, ", ")}]"
  defp yaml_value(v), do: to_string(v)
end
