defmodule LongWeb.Plugs.Locale do
  @moduledoc """
  Resolves the request locale and sets it for Gettext + stashes it in the
  session so the LiveView `on_mount` (`LongWeb.LocaleHook`) can pick it up
  (the LiveView runs in a different process from this plug).

  Priority: session (set by the language switcher) → `Accept-Language` → default.
  """

  import Plug.Conn

  @supported ~w(en zh)
  @default "en"

  def supported, do: @supported

  def init(opts), do: opts

  def call(conn, _opts) do
    locale = normalize(get_session(conn, :locale) || from_header(conn) || @default)
    Gettext.put_locale(LongWeb.Gettext, locale)

    conn
    |> put_session(:locale, locale)
    |> assign(:locale, locale)
  end

  defp from_header(conn) do
    case get_req_header(conn, "accept-language") do
      [value | _] ->
        value |> String.split(",") |> List.first("") |> String.split(";") |> List.first("") |> String.trim()

      _ ->
        nil
    end
  end

  # zh, zh-CN, zh-Hans, … → "zh"; en, en-US, … → "en"; anything else → default.
  defp normalize(locale) when locale in @supported, do: locale
  defp normalize("zh" <> _), do: "zh"
  defp normalize("en" <> _), do: "en"
  defp normalize(_), do: @default
end
