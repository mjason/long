defmodule Mix.Tasks.Long.Chat do
  @moduledoc """
  Interactive REPL for the agent. Opens a session (or resumes `--session
  <id>`) and reads stdin lines, streaming the agent's response back as it
  comes. Same code path the LiveView / Telegram bot use.

      mix long.chat
      mix long.chat --session 21c5ca03-…
      mix long.chat --title "ad-hoc playground"
  """
  use Mix.Task

  @shortdoc "Interactive terminal chat with the agent"

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(argv, switches: [session: :string, title: :string])

    Long.CLI.chat_loop(session_id: opts[:session], title: opts[:title])
  end
end
