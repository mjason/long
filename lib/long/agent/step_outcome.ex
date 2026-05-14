defmodule Long.Agent.StepOutcome do
  @moduledoc """
  Result of a single tool dispatch. Mirrors `agent_loop.StepOutcome`:

  - `data` — what gets fed back to the LLM as the `tool_result` content
  - `next_prompt` — synthetic system/user text appended to the next user turn.
    A nil/empty `next_prompt` is the signal "I'm done, exit the loop cleanly".
  - `should_exit?` — force the loop to terminate immediately (used by
    `ask_user` to hand control back to the human).
  """

  @type t :: %__MODULE__{
          data: any(),
          next_prompt: String.t() | nil,
          should_exit?: boolean()
        }

  defstruct data: nil, next_prompt: "", should_exit?: false

  def done(data \\ nil), do: %__MODULE__{data: data, next_prompt: nil}

  def cont(data, next_prompt \\ "\n"),
    do: %__MODULE__{data: data, next_prompt: next_prompt}

  def exit_with(data), do: %__MODULE__{data: data, should_exit?: true}
end
