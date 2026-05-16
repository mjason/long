defmodule LongWeb.PageController do
  use LongWeb, :controller

  def home(conn, _params) do
    render(conn, :home, dev_routes?: Application.get_env(:long, :dev_routes, false))
  end
end
