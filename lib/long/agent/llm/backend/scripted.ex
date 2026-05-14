defmodule Long.Agent.LLM.Backend.Scripted do
  @moduledoc """
  Test-only backend that returns canned `%Response{}` values from a queue
  managed by an Agent process. Each call to `stream_chat/3` pops the next
  response and replays it as a Stream of synthetic events.

      backend = Scripted.start([
        Response.from_blocks([%{type: :text, text: "calling tool"},
                              %{type: :tool_use, id: "t1", name: "file_read", input: %{"path" => "a.txt"}}]),
        Response.from_blocks([%{type: :text, text: "done"}])
      ])

  Behaves identically to a real backend from the loop's perspective.
  """

  @behaviour Long.Agent.LLM.Backend

  defstruct [:pid]

  def start(responses) when is_list(responses) do
    {:ok, pid} = Agent.start_link(fn -> responses end)
    %__MODULE__{pid: pid}
  end

  def stop(%__MODULE__{pid: pid}), do: Agent.stop(pid)

  @impl true
  def stream_chat(%__MODULE__{pid: pid}, _messages, _opts) do
    response =
      Agent.get_and_update(pid, fn
        [] -> {nil, []}
        [h | t] -> {h, t}
      end)

    if is_nil(response) do
      [{:error, :script_exhausted}]
    else
      response_to_events(response)
    end
  end

  defp response_to_events(response) do
    text_events =
      response.blocks
      |> Enum.filter(&(&1[:type] == :text))
      |> Enum.map(fn %{text: text} -> {:text_delta, text} end)

    thinking_events =
      response.blocks
      |> Enum.filter(&(&1[:type] == :thinking))
      |> Enum.map(fn b -> {:thinking_delta, b[:thinking] || ""} end)

    tool_events =
      response.tool_calls
      |> Enum.flat_map(fn tc ->
        [
          {:tool_use_start, %{id: tc.id, name: tc.name}},
          {:tool_use_done, %{id: tc.id, name: tc.name, input: tc.input}}
        ]
      end)

    thinking_events ++ text_events ++ tool_events ++ [{:done, response}]
  end
end
