defmodule LongWeb.PageController do
  use LongWeb, :controller

  # Mirror the router's gating (router.ex:45,68) at compile time so the
  # template and the actual dev routes can't drift in different builds.
  @dev_routes? Application.compile_env(:long, :dev_routes, false)

  def home(conn, _params), do: render(conn, :home, dev_routes?: @dev_routes?)
end
