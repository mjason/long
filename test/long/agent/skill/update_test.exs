defmodule Long.Agent.Skill.UpdateTest do
  use Long.DataCase, async: false

  alias Long.Agent
  alias Long.Agent.Skill.Store
  alias Long.Jido.Tools.SkillUpdate

  setup do
    cfg = Application.get_env(:long, Long.Agent, [])
    tmp = Path.join(System.tmp_dir!(), "skills_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)
    Application.put_env(:long, Long.Agent, Keyword.put(cfg, :skill_root, tmp))
    Store.reindex()

    on_exit(fn ->
      Application.put_env(:long, Long.Agent, cfg)
      File.rm_rf!(tmp)
      Store.reindex()
    end)

    {:ok, tmp: tmp}
  end

  defp body(name) do
    {:ok, skill} = Store.get(name)
    String.trim(skill.body)
  end

  describe "Store.update_skill/2" do
    test "rewrites the body, keeping name + description" do
      {:ok, _} = Store.create_skill("editme", "Original desc", "Old body.")

      assert {:ok, _dir} = Store.update_skill("editme", body: "New body.")
      assert body("editme") == "New body."

      assert {:ok, skill} = Store.get("editme")
      assert skill.description == "Original desc"
      assert skill.name == "editme"
    end

    test "updates the description and leaves the body untouched" do
      {:ok, _} = Store.create_skill("redesc", "Old desc", "Keep me.")

      assert {:ok, _} = Store.update_skill("redesc", description: "Fresh desc")
      assert {:ok, %{description: "Fresh desc"}} = Store.get("redesc")
      assert body("redesc") == "Keep me."
    end

    test "preserves existing frontmatter (tags) when editing the body", %{tmp: tmp} do
      dir = Path.join(tmp, "tagged")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "SKILL.md"), """
      ---
      name: "tagged"
      description: "Has tags"
      tags:
        - alpha
        - beta
      ---

      Body one.
      """)

      Store.reindex()
      assert {:ok, %{tags: ["alpha", "beta"]}} = Store.get("tagged")

      assert {:ok, _} = Store.update_skill("tagged", body: "Body two.")
      assert body("tagged") == "Body two."
      assert {:ok, %{tags: ["alpha", "beta"]}} = Store.get("tagged")
    end

    test "a member can only update a personal skill they own" do
      {:ok, _} = Store.create_skill("owned", "personal", "v1", member_id: "mem-1")

      assert {:error, :not_found} = Store.update_skill("owned", body: "v2", member_id: "mem-2")
      assert body("owned") == "v1"

      assert {:ok, _} = Store.update_skill("owned", body: "v2", member_id: "mem-1")
      assert body("owned") == "v2"
    end

    test "returns :not_found for a missing skill" do
      assert {:error, :not_found} = Store.update_skill("ghost", body: "x")
    end
  end

  describe "skill_update tool" do
    defp bind(role) do
      {:ok, hh} = Agent.create_group(%{name: "H-#{:rand.uniform(99999)}"})
      {:ok, m} = Agent.create_member(%{group_id: hh.id, display_name: "X", relation: :self, role: role})
      sess = Agent.start_session!(%{title: "t"})

      {:ok, _} =
        Agent.create_bot_user(%{
          platform: :telegram,
          external_id: "u-#{:rand.uniform(999_999)}",
          session_id: sess.id,
          member_id: m.id
        })

      {sess.id, m.id}
    end

    test "a member edits their own personal skill" do
      {sid, mid} = bind(:member)
      {:ok, _} = Store.create_skill("mine", "d", "before", member_id: mid)

      assert {:ok, %{status: "updated", name: "mine"}} =
               SkillUpdate.run(%{name: "mine", body: "after"}, %{session_id: sid})

      assert body("mine") == "after"
    end

    test "an owner edits a shared/global skill" do
      {sid, _mid} = bind(:owner)
      {:ok, _} = Store.create_skill("team", "d", "v1")

      assert {:ok, %{status: "updated"}} =
               SkillUpdate.run(%{name: "team", body: "v2"}, %{session_id: sid})

      assert body("team") == "v2"
    end

    test "a non-owner cannot edit a global skill" do
      {sid, _mid} = bind(:member)
      {:ok, _} = Store.create_skill("teamg", "d", "v1")

      assert {:ok, %{status: "error", msg: msg}} =
               SkillUpdate.run(%{name: "teamg", body: "v2"}, %{session_id: sid})

      assert msg =~ "owner"
      assert body("teamg") == "v1"
    end

    test "rejects an unbound web chat" do
      sess = Agent.start_session!(%{title: "web"})

      assert {:ok, %{status: "error", msg: msg}} =
               SkillUpdate.run(%{name: "x", body: "y"}, %{session_id: sess.id})

      assert msg =~ "/bind"
    end

    test "is a no-op error when neither description nor body is given" do
      {sid, mid} = bind(:member)
      {:ok, _} = Store.create_skill("noop", "d", "keep", member_id: mid)

      assert {:ok, %{status: "error"}} = SkillUpdate.run(%{name: "noop"}, %{session_id: sid})
      assert body("noop") == "keep"
    end
  end
end
