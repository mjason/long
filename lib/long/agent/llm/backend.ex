defmodule Long.Agent.LLM.Backend do
  @moduledoc """
  Behaviour every backend (Claude, OpenAI, Mixin, …) implements. Returns a
  `Stream` of tagged events:

  - `{:text_delta, text}` – incremental assistant text
  - `{:thinking_delta, text}` – incremental thinking (Claude/DeepSeek)
  - `{:tool_use_start, %{id, name}}` – tool-use block starting
  - `{:tool_use_delta, %{partial_json: ...}}` – streaming tool args JSON
  - `{:tool_use_done, %{id, name, input}}` – tool args complete
  - `{:done, %Long.Agent.LLM.Response{}}` – terminal event with full response
  - `{:error, reason}` – terminal error event
  """

  alias Long.Agent.LLM.Response

  @type event ::
          {:text_delta, String.t()}
          | {:thinking_delta, String.t()}
          | {:tool_use_start, %{id: String.t(), name: String.t()}}
          | {:tool_use_delta, %{partial_json: String.t()}}
          | {:tool_use_done, %{id: String.t(), name: String.t(), input: map()}}
          | {:done, Response.t()}
          | {:error, term()}

  @type messages :: [map()]

  @callback stream_chat(backend :: struct(), messages, opts :: keyword()) :: Enumerable.t()

  def stream_chat(%mod{} = backend, messages, opts \\ []),
    do: mod.stream_chat(backend, messages, opts)
end
