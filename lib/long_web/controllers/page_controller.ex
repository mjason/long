defmodule LongWeb.PageController do
  use LongWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
