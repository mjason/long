defmodule Long.CopyTest do
  # async: false — `Copy` caches DB overrides in a global persistent_term.
  use Long.DataCase, async: false

  alias Long.Agent
  alias Long.Copy

  test "resolves built-in defaults per locale, with fallback and key passthrough" do
    assert Copy.t("bots.cleared", %{}, "en") =~ "Cleared"
    assert Copy.t("bots.cleared", %{}, "zh") =~ "已清空"

    # unknown locale → default locale (en)
    assert Copy.t("bots.cleared", %{}, "fr") =~ "Cleared"

    # locale normalization (zh-Hans / en-US → zh / en)
    assert Copy.t("bots.cleared", %{}, "zh-Hans") =~ "已清空"
    assert Copy.t("bots.cleared", %{}, "en-US") =~ "Cleared"

    # unknown key → the key itself
    assert Copy.t("nope.not_a_key") == "nope.not_a_key"
  end

  test "interpolates %{name} bindings" do
    out = Copy.t("bots.bind_ok", %{member: "太子", group: "HOME"}, "en")
    assert out =~ "太子" and out =~ "HOME"

    zh = Copy.t("notify.no_match", %{target: "X", options: "A, B"}, "zh")
    assert zh =~ "X" and zh =~ "A, B"
  end

  test "a DB override wins over the built-in after reload, and clears on removal" do
    {:ok, _} = Agent.upsert_phrase(%{key: "bots.btw_ack", locale: "en", text: "Custom %{x}!"})
    :ok = Copy.reload()

    assert Copy.t("bots.btw_ack", %{x: "Y"}, "en") == "Custom Y!"
    # un-overridden locale still uses the built-in
    assert Copy.t("bots.btw_ack", %{}, "zh") =~ "上下文"

    # remove the override → back to the built-in
    {:ok, rows} = Agent.list_phrases()
    Enum.each(rows, &Agent.destroy_phrase!/1)
    :ok = Copy.reload()
    assert Copy.t("bots.btw_ack", %{}, "en") =~ "Got it"
  end

  test "global default locale override changes Copy.default_locale; blank clears it" do
    on_exit(fn -> Copy.put_default_locale(nil) end)

    base = Copy.default_locale()
    assert Copy.default_locale_setting() == nil

    Copy.put_default_locale("zh")
    assert Copy.default_locale_setting() == "zh"
    assert Copy.default_locale() == "zh"
    # an unqualified t/1 now renders in the new global default
    assert Copy.t("bots.cleared") =~ "已清空"

    Copy.put_default_locale(nil)
    assert Copy.default_locale_setting() == nil
    assert Copy.default_locale() == base
  end
end
