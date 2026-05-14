defmodule Long.Agent.Tools.AskUser do
  @moduledoc """
  Port of `do_ask_user`. The agent hands control back to the human; the loop
  terminates with an `{:ask_user, …}` event. Caller resumes by starting a new
  loop run with the human's answer appended to the messages list.
  """

  @behaviour Long.Agent.Tool

  alias Long.Agent.{StepOutcome, Tool}

  @impl true
  def name, do: "ask_user"

  @impl true
  def schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => name(),
        "description" =>
          "Ask the human for input. The loop pauses and returns control to the caller.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "question" => %{"type" => "string"},
            "candidates" => %{"type" => "array", "items" => %{"type" => "string"}}
          },
          "required" => ["question"]
        }
      }
    }
  end

  @impl true
  def run(args, _ctx) do
    payload = %{
      "question" => args["question"] || "请提供输入：",
      "candidates" => args["candidates"] || []
    }

    Tool.emit("[Action] Waiting for your answer …\n", StepOutcome.exit_with(payload))
  end
end
