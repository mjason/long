defmodule LongWeb.WechatLive.LoginI18nTest do
  @moduledoc "Proves the Petal + i18n toolchain end-to-end on the converted login page."
  use LongWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "renders a Petal button and English copy by default", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/wechat")

    # Petal Components rendered (its buttons carry the pc-button class).
    assert html =~ "pc-button"
    # English (default locale).
    assert html =~ "WeChat iLink bot login"
    assert html =~ "Start login"
  end

  test "renders Chinese when the session locale is zh", %{conn: conn} do
    conn = Plug.Test.init_test_session(conn, %{locale: "zh"})
    {:ok, _lv, html} = live(conn, "/wechat")

    assert html =~ "微信 iLink 机器人登录"
    assert html =~ "开始登录"
    refute html =~ "WeChat iLink bot login"
  end
end
