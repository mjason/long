defmodule Long.Agent.Tool do
  @moduledoc """
  Behaviour every agent tool implements. Mirrors `GenericAgentHandler.do_*` in
  `ga.py` — each implementation streams free-text output (for UI display) and
  terminates with a `Long.Agent.StepOutcome` that gets fed back to the LLM.

  A tool's `run/2` returns an Enumerable that yields one of:

  - `{:output, text}` — a chunk of display-only text (not fed to the model)
  - `{:outcome, %StepOutcome{}}` — terminal; must be the last element

  The Long.Agent.Loop drives the stream, surfaces `{:output, _}` to the UI
  layer, and uses the final outcome to build the next user turn.
  """

  alias Long.Agent.{StepOutcome, ToolContext}

  @callback name() :: String.t()
  @callback schema() :: map()
  @callback run(args :: map(), ctx :: ToolContext.t()) :: Enumerable.t()

  @doc """
  Convenience constructor for the trivial "output one line and return outcome"
  pattern most tools end up using.
  """
  def emit(text, %StepOutcome{} = outcome) do
    [{:output, text}, {:outcome, outcome}]
  end
end
