defmodule LongWeb.ManageLive.GroupsTest do
  use LongWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Long.Agent

  test "Groups page renders the English binding instructions", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/manage/groups")

    assert html =~ "Groups"
    assert html =~ "How members link their WeChat / Telegram"
    assert html =~ "do <em>not</em> each scan"
    assert html =~ "New group"
    refute html =~ "组"
  end

  test "shows each member's /bind command, English relation, and bound status", %{conn: conn} do
    {:ok, hh} = Agent.create_group(%{name: "Test Home"})
    {:ok, m} = Agent.create_member(%{group_id: hh.id, display_name: "Alex", relation: :self})

    {:ok, _view, html} = live(conn, ~p"/manage/groups")

    assert html =~ "Test Home"
    assert html =~ "Alex"
    assert html =~ "Self"
    assert html =~ "/bind #{m.bind_code}"
    assert html =~ "Not bound"

    Agent.destroy_group!(hh)
  end

  test "Channels page lists WeChat accounts with a member picker, in English", %{conn: conn} do
    {:ok, hh} = Agent.create_group(%{name: "Home"})
    {:ok, m} = Agent.create_member(%{group_id: hh.id, display_name: "Dad", relation: :other})
    name = "dad-#{System.unique_integer([:positive])}"
    {:ok, _} = Agent.upsert_wechat_credential(%{name: name, member_id: m.id})

    {:ok, _view, html} = live(conn, ~p"/manage/credentials")

    assert html =~ "WeChat accounts"
    assert html =~ name
    assert html =~ "Member (role)"
    assert html =~ "Add"
    assert html =~ "Dad"
    refute html =~ "已连接"
    refute html =~ "扫码"

    {:ok, row} = Agent.get_wechat_credential(name)
    Agent.destroy_wechat_credential!(row)
    Long.Agent.Bots.Wechat.Manager.reconcile()
    Agent.destroy_group!(hh)
  end

  test "assigning a member to a WeChat account via the picker persists", %{conn: conn} do
    {:ok, hh} = Agent.create_group(%{name: "Pick Home"})
    {:ok, m} = Agent.create_member(%{group_id: hh.id, display_name: "Pat", relation: :self})
    name = "pick-wc-#{System.unique_integer([:positive])}"
    {:ok, _} = Agent.upsert_wechat_credential(%{name: name})

    {:ok, view, _html} = live(conn, ~p"/manage/credentials")

    view
    |> form("#memsel-assign_wechat_member-#{name}", %{member_id: m.id})
    |> render_change()

    assert {:ok, %{member_id: assigned}} = Agent.get_wechat_credential(name)
    assert assigned == m.id

    # …and "— unassigned —" clears it back to nil
    view
    |> form("#memsel-assign_wechat_member-#{name}", %{member_id: ""})
    |> render_change()

    assert {:ok, %{member_id: nil}} = Agent.get_wechat_credential(name)

    {:ok, row} = Agent.get_wechat_credential(name)
    Agent.destroy_wechat_credential!(row)
    Long.Agent.Bots.Wechat.Manager.reconcile()
    Agent.destroy_group!(hh)
  end

  test "assigning a member to a Telegram bot via the picker persists", %{conn: conn} do
    {:ok, hh} = Agent.create_group(%{name: "Pick Home"})
    {:ok, m} = Agent.create_member(%{group_id: hh.id, display_name: "Sam", relation: :self})
    name = "pick-tg-#{System.unique_integer([:positive])}"
    {:ok, _} = Agent.upsert_telegram_credential(%{name: name, bot_token: "t"})

    {:ok, view, _html} = live(conn, ~p"/manage/credentials")

    view
    |> form("#memsel-assign_telegram_member-#{name}", %{member_id: m.id})
    |> render_change()

    assert {:ok, %{member_id: assigned}} = Agent.get_telegram_credential(name)
    assert assigned == m.id

    {:ok, row} = Agent.get_telegram_credential(name)
    Agent.destroy_telegram_credential!(row)
    Agent.destroy_group!(hh)
  end

  test "Channels page lets a Telegram bot be bound to a member too", %{conn: conn} do
    {:ok, hh} = Agent.create_group(%{name: "Home"})
    {:ok, m} = Agent.create_member(%{group_id: hh.id, display_name: "Mom", relation: :other})
    name = "mom-bot-#{System.unique_integer([:positive])}"
    {:ok, _} = Agent.upsert_telegram_credential(%{name: name, bot_token: "t", member_id: m.id})

    {:ok, _view, html} = live(conn, ~p"/manage/credentials")

    assert html =~ name
    # Telegram table now has the same Member (role) column WeChat has
    assert html =~ "Member (role)"
    assert html =~ "assign_telegram_member"
    assert html =~ "Mom"

    {:ok, row} = Agent.get_telegram_credential(name)
    Agent.destroy_telegram_credential!(row)
    Agent.destroy_group!(hh)
  end

  test "Phrases page lists the catalog and an override round-trips", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/manage/phrases")

    assert html =~ "Phrases"
    assert html =~ "bots.cleared"
    assert html =~ "Built-in default"

    # set an override for (bots.btw_ack, en)
    html =
      view
      |> form("#ph-bots-btw_ack-en",
        key: "bots.btw_ack",
        locale: "en",
        text: "Custom override here"
      )
      |> render_submit()

    assert html =~ "Phrase saved."
    assert Long.Copy.t("bots.btw_ack", %{}, "en") == "Custom override here"

    # clear it (empty text) → back to the built-in default
    view
    |> form("#ph-bots-btw_ack-en", key: "bots.btw_ack", locale: "en", text: "")
    |> render_submit()

    assert Long.Copy.t("bots.btw_ack", %{}, "en") =~ "Got it"
  end

  test "Skills page can create a shared skill via the form", %{conn: conn} do
    cfg = Application.get_env(:long, Long.Agent, [])
    tmp = Path.join(System.tmp_dir!(), "webskills_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:long, Long.Agent, Keyword.put(cfg, :skill_root, tmp))
    Long.Agent.Skill.Store.reindex()

    on_exit(fn ->
      Application.put_env(:long, Long.Agent, cfg)
      File.rm_rf!(tmp)
      Long.Agent.Skill.Store.reindex()
    end)

    {:ok, view, html} = live(conn, ~p"/manage/skills")
    assert html =~ "shared skill"

    html =
      view
      |> form("form[phx-submit=new_shared_skill]",
        skill: %{name: "web-shared-skill", description: "made via web", body: "do the thing"}
      )
      |> render_submit()

    assert html =~ "Created shared skill"
    assert {:ok, %{scope: :global}} = Long.Agent.Skill.Store.get("web-shared-skill")
  end

  test "Skills page opens a skill to show its full SKILL.md", %{conn: conn} do
    cfg = Application.get_env(:long, Long.Agent, [])
    tmp = Path.join(System.tmp_dir!(), "viewskill_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:long, Long.Agent, Keyword.put(cfg, :skill_root, tmp))
    Long.Agent.Skill.Store.reindex()

    on_exit(fn ->
      Application.put_env(:long, Long.Agent, cfg)
      File.rm_rf!(tmp)
      Long.Agent.Skill.Store.reindex()
    end)

    {:ok, _} = Long.Agent.Skill.Store.create_skill("viewable-skill", "what it does", "Step one.\nStep two.")

    {:ok, view, html} = live(conn, ~p"/manage/skills")
    # the list shows the name/description but not the body until you open it
    assert html =~ "viewable-skill"
    refute html =~ "Step one."

    html =
      view
      |> element("button[phx-value-name=viewable-skill][phx-click=view_skill]")
      |> render_click()

    assert html =~ "Skill · viewable-skill"
    assert html =~ "Step one."
    assert html =~ "Step two."
  end

  test "creating a group via the form works", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/manage/groups")

    html =
      view
      |> form("form[phx-submit=new_group]", group: %{name: "Fam One"})
      |> render_submit()

    assert html =~ "Fam One"
    assert html =~ "Group created."

    Agent.list_groups!()
    |> Enum.filter(&(&1.name == "Fam One"))
    |> Enum.each(&Agent.destroy_group!/1)
  end

  test "Groups page sets group + member default language", %{conn: conn} do
    {:ok, hh} = Agent.create_group(%{name: "Lang Home"})
    {:ok, m} = Agent.create_member(%{group_id: hh.id, display_name: "Kid", relation: :other})

    {:ok, view, html} = live(conn, ~p"/manage/groups")
    assert html =~ "Default language"
    assert html =~ "中文"

    view
    |> form("#locsel-set_group_locale-#{hh.id}", %{locale: "zh"})
    |> render_change()

    assert {:ok, %{locale: "zh"}} = Agent.get_group(hh.id)

    view
    |> form("#locsel-set_member_locale-#{m.id}", %{locale: "en"})
    |> render_change()

    assert {:ok, %{locale: "en"}} = Agent.get_member(m.id)

    Agent.destroy_group!(hh)
  end

  test "setting one member's language keeps the other members' selects", %{conn: conn} do
    {:ok, hh} = Agent.create_group(%{name: "Two-Member"})
    {:ok, a} = Agent.create_member(%{group_id: hh.id, display_name: "A", relation: :self})
    {:ok, b} = Agent.create_member(%{group_id: hh.id, display_name: "B", relation: :other})

    {:ok, view, html} = live(conn, ~p"/manage/groups")
    assert html =~ "locsel-set_member_locale-#{a.id}"
    assert html =~ "locsel-set_member_locale-#{b.id}"

    html =
      view
      |> form("#locsel-set_member_locale-#{a.id}", %{locale: "zh"})
      |> render_change()

    # After changing A's language, B's language select must still exist.
    assert html =~ "locsel-set_member_locale-#{a.id}"
    assert html =~ "locsel-set_member_locale-#{b.id}"

    Agent.destroy_group!(hh)
  end

  test "Channels page sets a WeChat account language", %{conn: conn} do
    {:ok, hh} = Agent.create_group(%{name: "H"})
    name = "wc-#{System.unique_integer([:positive])}"
    {:ok, _} = Agent.upsert_wechat_credential(%{name: name})

    {:ok, view, html} = live(conn, ~p"/manage/credentials")
    assert html =~ "Language"

    view
    |> form("#locsel-set_wechat_locale-#{name}", %{locale: "zh"})
    |> render_change()

    assert {:ok, %{locale: "zh"}} = Agent.get_wechat_credential(name)

    {:ok, row} = Agent.get_wechat_credential(name)
    Agent.destroy_wechat_credential!(row)
    Long.Agent.Bots.Wechat.Manager.reconcile()
    Agent.destroy_group!(hh)
  end

  test "Groups page sets the system-wide default language", %{conn: conn} do
    on_exit(fn -> Long.Copy.put_default_locale(nil) end)

    {:ok, view, html} = live(conn, ~p"/manage/groups")
    assert html =~ "System default language"

    view
    |> form("#locsel-set_default_locale-system", %{locale: "zh"})
    |> render_change()

    assert Long.Copy.default_locale() == "zh"
  end

  test "Groups page sets the system timezone, stored as the user_timezone memory", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/manage/groups")
    assert html =~ "System timezone"

    view
    |> form("#tzsel-set_timezone", %{timezone: "Europe/London"})
    |> render_change()

    assert Long.Agent.user_timezone() == "Europe/London"
  end
end
