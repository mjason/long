defmodule Long.Agent.LLM do
  @moduledoc """
  Public facade for the LLM client layer. Phase 1 port of
  `llmcore.py` (BaseSession + NativeClaudeSession + NativeOAISession + MixinSession).

  Usage:

      backend = Long.Agent.LLM.resolve!("claude_main")
      backend
      |> Long.Agent.LLM.chat(messages, tools: tools, system: system)
      |> Enum.reduce(%{text: "", response: nil}, fn
        {:text_delta, t}, %{text: txt} = s -> %{s | text: txt <> t}
        {:done, resp}, s -> %{s | response: resp}
        _, s -> s
      end)

  Messages are kept in canonical Anthropic content-block form:

      %{role: :user, content: [%{type: :text, text: "hi"}]}

  Backends convert to provider-specific wire formats as needed.
  """

  alias Long.Agent.LLM.{Backend, Resolver}

  defdelegate resolve!(name_or_id), to: Resolver, as: :resolve!
  defdelegate resolve(name_or_id), to: Resolver, as: :resolve

  def chat(backend, messages, opts \\ []), do: Backend.stream_chat(backend, messages, opts)
end
