defmodule Long.Agent.Skill.CreateTest do
  use Long.DataCase, async: false

  alias Long.Agent
  alias Long.Agent.Skill.Store
  alias Long.Jido.Tools.SkillCreate

  setup do
    # Point skill_root at a throwaway dir so we don't touch real skills.
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

  describe "Store.create_skill/4" do
    test "creates a SHARED (global) skill visible to everyone", %{tmp: tmp} do
      assert {:ok, dir} = Store.create_skill("daily-standup", "Run the standup", "Do X then Y.")
      assert dir == Path.join(tmp, "daily-standup")
      assert File.read!(Path.join(dir, "SKILL.md")) =~ "name: \"daily-standup\""

      assert {:ok, skill} = Store.get("daily-standup")
      assert skill.scope == :global
      assert "daily-standup" in (Store.visible_skills("anyone") |> Enum.map(& &1.name))
    end

    test "creates a PERSONAL skill only its owner sees", %{tmp: _tmp} do
      assert {:ok, _} = Store.create_skill("my-notes", "personal", "...", member_id: "mem-1")

      assert {:ok, skill} = Store.get("my-notes")
      assert skill.scope == :personal and skill.owner_member_id == "mem-1"
      assert "my-notes" in (Store.visible_skills("mem-1") |> Enum.map(& &1.name))
      refute "my-notes" in (Store.visible_skills("mem-2") |> Enum.map(& &1.name))
    end

    test "rejects a duplicate name" do
      assert {:ok, _} = Store.create_skill("dup", "first", "")
      assert {:error, :name_taken} = Store.create_skill("dup", "second", "")
    end

    test "requires name + description" do
      assert {:error, :name_required} = Store.create_skill("", "d", "")
      assert {:error, :description_required} = Store.create_skill("n", "", "")
    end

    test "handles a non-ASCII (Chinese) name" do
      assert {:ok, _} = Store.create_skill("每日汇报", "每天汇报", "步骤……")
      assert {:ok, %{scope: :global}} = Store.get("每日汇报")
    end
  end

  describe "skill_create tool" do
    defp bind(role) do
      {:ok, hh} = Agent.create_group(%{name: "H-#{:rand.uniform(99999)}"})
      {:ok, m} = Agent.create_member(%{group_id: hh.id, display_name: "X", relation: :self, role: role})
      sess = Agent.start_session!(%{title: "t"})

      {:ok, _} =
        Agent.create_bot_user(%{platform: :telegram, external_id: "u-#{:rand.uniform(999_999)}", session_id: sess.id, member_id: m.id})

      sess.id
    end

    test "an owner can create a SHARED skill" do
      sid = bind(:owner)

      assert {:ok, %{status: "created", scope: "shared"}} =
               SkillCreate.run(%{name: "team-x", description: "d", body: "b", shared: true}, %{session_id: sid})

      assert {:ok, %{scope: :global}} = Store.get("team-x")
    end

    test "a non-owner cannot create a shared skill" do
      sid = bind(:member)

      assert {:ok, %{status: "error", msg: msg}} =
               SkillCreate.run(%{name: "team-y", description: "d", shared: true}, %{session_id: sid})

      assert msg =~ "owner"
      assert {:error, :not_found} = Store.get("team-y")
    end

    test "a member creates a personal skill by default" do
      sid = bind(:member)

      assert {:ok, %{status: "created", scope: "personal"}} =
               SkillCreate.run(%{name: "mine-z", description: "d", body: ""}, %{session_id: sid})

      assert {:ok, %{scope: :personal}} = Store.get("mine-z")
    end

    test "a web chat with no members at all still can't create (nothing to act as)" do
      sess = Agent.start_session!(%{title: "web"})

      assert {:ok, %{status: "error", msg: msg}} =
               SkillCreate.run(%{name: "nope", description: "d", shared: true}, %{session_id: sess.id})

      assert msg =~ "/bind"
    end

    test "a web chat (no bound account) acts as the owner when members exist" do
      {:ok, hh} = Agent.create_group(%{name: "Home-#{:rand.uniform(99_999)}"})
      {:ok, owner} = Agent.create_member(%{group_id: hh.id, display_name: "Me", relation: :self, role: :owner})
      sess = Agent.start_session!(%{title: "web"})

      # no bot_user is bound, so the session falls back to the owner member
      assert %{id: oid} = Agent.member_for_session(sess.id)
      assert oid == owner.id

      # which means the web console can create a shared skill without /bind
      assert {:ok, %{status: "created", scope: "shared"}} =
               SkillCreate.run(%{name: "web-owner-skill", description: "d", body: "b", shared: true}, %{session_id: sess.id})
    end
  end
end
