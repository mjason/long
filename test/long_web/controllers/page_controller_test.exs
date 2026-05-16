defmodule LongWeb.PageControllerTest do
  use LongWeb.ConnCase

  test "GET / renders the navigation hub", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ "Long"
    assert html =~ "Workspaces"
    assert html =~ ~s|href="/chat"|
    assert html =~ ~s|href="/manage"|
  end
end
