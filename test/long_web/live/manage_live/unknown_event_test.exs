defmodule LongWeb.ManageLive.UnknownEventTest do
  use LongWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "an unknown/mismatched event no-ops instead of crashing the console", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/manage/credentials")

    # A phx event with no matching clause (or unexpected params) used to raise
    # FunctionClauseError and crash the LiveView. The catch-all must absorb it.
    assert render_hook(view, "totally_bogus_event", %{"whatever" => "1"})
    assert render_hook(view, "assign_wechat_member", %{"unexpected" => "shape"})

    # The view is still alive and rendering.
    assert render(view) =~ "WeChat"
  end
end
