defmodule LongWeb.LocaleHook do
  @moduledoc """
  `on_mount` hook for live routes: applies the session locale (set by
  `LongWeb.Plugs.Locale`) to Gettext inside the LiveView process and exposes
  it as `@locale` for the language switcher.
  """

  import Phoenix.Component, only: [assign: 3]

  def on_mount(:default, _params, session, socket) do
    locale = session["locale"] || "en"
    Gettext.put_locale(LongWeb.Gettext, locale)
    {:cont, assign(socket, :locale, locale)}
  end
end
