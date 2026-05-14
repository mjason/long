defmodule Mix.Tasks.Long.Sessions do
  @moduledoc """
  List agent sessions, newest first.

      mix long.sessions
  """
  use Mix.Task

  @shortdoc "List agent sessions"

  @impl true
  def run(_argv) do
    Mix.Task.run("app.start")
    Long.CLI.list_sessions()
  end
end
