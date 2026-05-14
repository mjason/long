defmodule Long.Agent.LLM.Backend.Echo do
  @moduledoc """
  Deterministic, no-network backend for dev/demo. Replays the last user
  message back as the assistant turn and emits one `:done`. Lets the UI
  work end-to-end without an API key configured.
  """

  @behaviour Long.Agent.LLM.Backend

  alias Long.Agent.LLM.Response

  defstruct name: "echo", chunk_size: 16

  @impl true
  def stream_chat(%__MODULE__{chunk_size: chunk_size}, messages, _opts) do
    text = response_text(messages)

    Stream.concat([
      chunked_deltas(text, chunk_size),
      [{:done, Response.from_blocks([%{type: :text, text: text}], stop_reason: :end_turn)}]
    ])
  end

  defp response_text(messages) do
    case last_user(messages) do
      nil -> "Echo backend is alive. Send something."
      input -> "(echo) " <> input
    end
  end

  defp last_user(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{role: :user, content: c} when is_binary(c) -> c
      %{role: :user, content: blocks} when is_list(blocks) -> extract_text(blocks)
      _ -> nil
    end)
  end

  defp extract_text(blocks) do
    blocks
    |> Enum.filter(&(&1[:type] == :text))
    |> Enum.map_join("\n", &(&1[:text] || ""))
  end

  defp chunked_deltas(text, chunk_size) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(chunk_size)
    |> Enum.map(fn graphs -> {:text_delta, IO.iodata_to_binary(graphs)} end)
  end
end
