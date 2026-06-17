defmodule LongWeb.ManageLive.ReflectionTest do
  use LongWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Long.Agent

  test "Reflection page renders the switch + off-peak hour", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/manage/reflection")

    assert html =~ "Reflection"
    assert html =~ "Silent reflection"
    assert html =~ "Off-peak hour"
  end

  test "toggling the switch persists to Setting and back", %{conn: conn} do
    assert Agent.reflection_enabled?()

    {:ok, view, _html} = live(conn, ~p"/manage/reflection")

    view |> element("button", "Turn off") |> render_click()
    refute Agent.reflection_enabled?()

    view |> element("button", "Turn on") |> render_click()
    assert Agent.reflection_enabled?()
  end

  test "setting the off-peak hour persists", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/manage/reflection")

    view
    |> element("form[phx-change='set_reflection_hour']")
    |> render_change(%{"hour" => "9"})

    assert Agent.reflection_hour() == 9
  end

  test "silent reflection tasks show under Reflection, not Scheduled", %{conn: conn} do
    {:ok, sess} = Agent.start_session(%{title: "x"})

    {:ok, _normal} =
      Agent.create_scheduled_task(%{
        name: "morning_brief",
        session_id: sess.id,
        prompt: "pull worklog",
        repeat: :daily
      })

    {:ok, _silent} =
      Agent.create_scheduled_task(%{
        name: Agent.reflection_task_name(sess.id),
        session_id: sess.id,
        prompt: "reflect",
        repeat: :daily,
        silent: true
      })

    {:ok, _v, scheduled_html} = live(conn, ~p"/manage/scheduled")
    assert scheduled_html =~ "morning_brief"
    refute scheduled_html =~ Agent.reflection_task_name(sess.id)

    {:ok, _v2, reflection_html} = live(conn, ~p"/manage/reflection")
    assert reflection_html =~ String.slice(sess.id, 0, 8)
  end
end
