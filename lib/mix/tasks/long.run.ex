defmodule Mix.Tasks.Long.Run do
  @moduledoc """
  One-shot agent invocation. Reads PROMPT from argv (or stdin if absent),
  prints the response, then exits.

      mix long.run "what's the time in UTC?"
      echo "summarize this" | mix long.run
  """
  use Mix.Task

  @shortdoc "Run one prompt through the agent and exit"

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, args, _} =
      OptionParser.parse(argv, switches: [session: :string, title: :string])

    prompt =
      case args do
        [] -> IO.read(:stdio, :eof) |> to_string() |> String.trim()
        parts -> Enum.join(parts, " ")
      end

    if prompt == "" do
      Mix.shell().error("no prompt given")
    else
      Long.CLI.run_once(prompt, session_id: opts[:session], title: opts[:title])
    end
  end
end
