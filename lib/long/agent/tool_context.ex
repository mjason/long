defmodule Long.Agent.ToolContext do
  @moduledoc """
  Context passed to every tool invocation. Holds the per-session info a tool
  needs to do its job without reaching into the loop's internals.

  - `:session_id` — Phase 0 Session UUID (nil for transient/ephemeral runs)
  - `:cwd` — working directory for file/code tools (sandboxed under the temp
    root by default)
  - `:memory_root` — root for L2/L3 memory artifacts
  - `:response` — the full LLM `%Response{}` for the current turn (lets tools
    inspect free-text blocks, e.g. `file_write` reading from `<file_content>`)
  - `:tool_index` / `:tool_count` — position in the current turn's tool batch
    (mirrors `_index` / `_tool_num` in `ga.py`)
  - `:turn` — current turn number
  """

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          cwd: String.t(),
          memory_root: String.t() | nil,
          response: Long.Agent.LLM.Response.t() | nil,
          tool_index: non_neg_integer(),
          tool_count: pos_integer(),
          turn: pos_integer()
        }

  defstruct [
    :session_id,
    :cwd,
    :memory_root,
    :response,
    tool_index: 0,
    tool_count: 1,
    turn: 1
  ]
end
