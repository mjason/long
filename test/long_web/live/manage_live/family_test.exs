defmodule LongWeb.ManageLive.FamilyTest do
  use LongWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Long.Agent

  test "Family page renders the English binding instructions", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/manage/households")

    assert html =~ "Family"
    assert html =~ "How members link their WeChat / Telegram"
    assert html =~ "do <em>not</em> each scan"
    assert html =~ "New household"
    refute html =~ "家庭组"
  end

  test "shows each member's /bind command, English relation, and bound status", %{conn: conn} do
    {:ok, hh} = Agent.create_household(%{name: "Test Home"})
    {:ok, m} = Agent.create_member(%{household_id: hh.id, display_name: "Alex", relation: :spouse})

    {:ok, _view, html} = live(conn, ~p"/manage/households")

    assert html =~ "Test Home"
    assert html =~ "Alex"
    assert html =~ "Spouse"
    assert html =~ "/bind #{m.bind_code}"
    assert html =~ "Not bound"

    Agent.destroy_household!(hh)
  end

  test "Channels page lists WeChat accounts with a member picker, in English", %{conn: conn} do
    {:ok, hh} = Agent.create_household(%{name: "Home"})
    {:ok, m} = Agent.create_member(%{household_id: hh.id, display_name: "Dad", relation: :parent})
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
    Agent.destroy_household!(hh)
  end

  test "Channels page lets a Telegram bot be bound to a member too", %{conn: conn} do
    {:ok, hh} = Agent.create_household(%{name: "Home"})
    {:ok, m} = Agent.create_member(%{household_id: hh.id, display_name: "Mom", relation: :parent})
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
    Agent.destroy_household!(hh)
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

  test "creating a household via the form works", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/manage/households")

    html =
      view
      |> form("form[phx-submit=new_household]", household: %{name: "Fam One"})
      |> render_submit()

    assert html =~ "Fam One"
    assert html =~ "Household created."

    Agent.list_households!()
    |> Enum.filter(&(&1.name == "Fam One"))
    |> Enum.each(&Agent.destroy_household!/1)
  end

  test "Family page sets household + member default language", %{conn: conn} do
    {:ok, hh} = Agent.create_household(%{name: "Lang Home"})
    {:ok, m} = Agent.create_member(%{household_id: hh.id, display_name: "Kid", relation: :child})

    {:ok, view, html} = live(conn, ~p"/manage/households")
    assert html =~ "Default language"
    assert html =~ "中文"

    view
    |> form("#locsel-set_household_locale-#{hh.id}", %{locale: "zh"})
    |> render_change()

    assert {:ok, %{locale: "zh"}} = Agent.get_household(hh.id)

    view
    |> form("#locsel-set_member_locale-#{m.id}", %{locale: "en"})
    |> render_change()

    assert {:ok, %{locale: "en"}} = Agent.get_member(m.id)

    Agent.destroy_household!(hh)
  end

  test "Channels page sets a WeChat account language", %{conn: conn} do
    {:ok, hh} = Agent.create_household(%{name: "H"})
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
    Agent.destroy_household!(hh)
  end
end
