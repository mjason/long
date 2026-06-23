defmodule LongWeb.LocaleController do
  @moduledoc "Language switcher: persists the chosen locale in the session and returns to the prior page."
  use LongWeb, :controller

  def set(conn, %{"locale" => locale}) do
    locale = if locale in LongWeb.Plugs.Locale.supported(), do: locale, else: "en"

    back =
      case get_req_header(conn, "referer") do
        [referer | _] when is_binary(referer) and referer != "" -> referer
        _ -> ~p"/manage"
      end

    conn
    |> put_session(:locale, locale)
    |> redirect(external: back)
  end
end
