defmodule LongWeb.ManageLive.MonitorsTest do
  use LongWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Long.Agent

  setup do
    {:ok, sess} = Agent.start_session(%{title: "monitors-page"})
    {:ok, sess: sess}
  end

  test "renders the monitors page and lists existing monitors", %{conn: conn, sess: sess} do
    {:ok, _m} =
      Agent.create_monitor(%{
        name: "render-mon",
        session_id: sess.id,
        script: "console.log('{}')",
        repeat: :every_n_minutes,
        every_n: 5
      })

    {:ok, _lv, html} = live(conn, "/manage/monitors")

    assert html =~ "Monitors"
    assert html =~ "render-mon"
  end

  test "the 'New monitor' button opens the create modal", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/manage/monitors")

    html = render_click(lv, "new_monitor", %{})

    assert html =~ "New monitor"
    # The script textarea (the code editor) is present.
    assert html =~ ~s|name="monitor[script]"|
  end

  test "creating a monitor through the form persists it", %{conn: conn, sess: sess} do
    {:ok, lv, _html} = live(conn, "/manage/monitors")
    render_click(lv, "new_monitor", %{})

    render_submit(lv, "save_monitor", %{
      "monitor" => %{
        "name" => "form-made",
        "script" => "console.log(JSON.stringify({notify:false}))",
        "repeat" => "every_n_minutes",
        "every_n" => "10",
        "schedule_time" => "00:00",
        "cooldown_minutes" => "30",
        "max_delay_hours" => "6",
        "secret_name" => "",
        "session_id" => sess.id,
        "enabled" => "true"
      }
    })

    assert {:ok, [m]} = Agent.list_monitors_for_session(sess.id)
    assert m.name == "form-made"
    assert m.every_n == 10
    assert m.cooldown_minutes == 30
  end
end
