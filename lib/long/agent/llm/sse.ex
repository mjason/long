defmodule Long.Agent.LLM.SSE do
  @moduledoc """
  Server-Sent Events parsers for Anthropic Messages and OpenAI chat/completions.
  Each `parse_*` function is suitable as the `parser_fn` argument to
  `Long.Agent.LLM.StreamRunner.stream/4`.

  Parser state shape is provider-specific but always carries a `:blocks` list
  (accumulated content blocks in Anthropic format) so `StreamRunner`'s default
  `:done` event has structured data to return.
  """

  alias Long.Agent.LLM.Response

  # ── Claude (Anthropic Messages SSE) ───────────────────────────────────────

  def claude_init_state do
    %{
      blocks: [],
      current_block: nil,
      tool_json_buf: "",
      stop_reason: nil,
      usage: %{},
      model: nil,
      finished?: false
    }
  end

  def parse_claude(buffer, state) do
    {lines, leftover} = take_sse_lines(buffer)
    {events, new_state} = Enum.reduce(lines, {[], state}, &handle_claude_line/2)
    {events, new_state, leftover}
  end

  defp handle_claude_line(line, {events, state}) do
    case parse_sse_line(line) do
      :skip ->
        {events, state}

      {:data, "[DONE]"} ->
        {events ++ finalize_claude(state), %{state | finished?: true}}

      {:data, json} ->
        case Jason.decode(json) do
          {:ok, evt} -> apply_claude_event(evt, state, events)
          _ -> {events, state}
        end
    end
  end

  defp apply_claude_event(%{"type" => "message_start"} = evt, state, events) do
    msg = evt["message"] || %{}

    {events,
     %{
       state
       | model: msg["model"] || state.model,
         usage: Map.merge(state.usage, msg["usage"] || %{})
     }}
  end

  defp apply_claude_event(
         %{"type" => "content_block_start", "content_block" => block},
         state,
         events
       ) do
    case block["type"] do
      "text" ->
        {events, %{state | current_block: %{type: :text, text: ""}}}

      "thinking" ->
        {events, %{state | current_block: %{type: :thinking, thinking: "", signature: ""}}}

      "tool_use" ->
        cb = %{type: :tool_use, id: block["id"] || "", name: block["name"] || "", input: %{}}

        {events ++ [{:tool_use_start, %{id: cb.id, name: cb.name}}],
         %{state | current_block: cb, tool_json_buf: ""}}

      _ ->
        {events, state}
    end
  end

  defp apply_claude_event(%{"type" => "content_block_delta", "delta" => delta}, state, events) do
    handle_claude_delta(delta, state, events)
  end

  defp apply_claude_event(
         %{"type" => "content_block_stop"},
         %{current_block: nil} = state,
         events
       ) do
    {events, state}
  end

  defp apply_claude_event(%{"type" => "content_block_stop"}, state, events) do
    {block, more_events} = finalize_current_claude_block(state)

    {events ++ more_events,
     %{state | blocks: state.blocks ++ [block], current_block: nil, tool_json_buf: ""}}
  end

  defp apply_claude_event(%{"type" => "message_delta", "delta" => delta} = evt, state, events) do
    usage = evt["usage"] || %{}

    {events,
     %{
       state
       | stop_reason: delta["stop_reason"] || state.stop_reason,
         usage: Map.merge(state.usage, usage)
     }}
  end

  defp apply_claude_event(%{"type" => "message_stop"}, state, events) do
    {events ++ finalize_claude(state), %{state | finished?: true}}
  end

  defp apply_claude_event(%{"type" => "error", "error" => err}, state, events) do
    msg = (is_map(err) && err["message"]) || inspect(err)
    {events ++ [{:error, "Anthropic SSE error: #{msg}"}], %{state | finished?: true}}
  end

  defp apply_claude_event(_evt, state, events), do: {events, state}

  defp handle_claude_delta(%{"type" => "text_delta", "text" => text}, state, events) do
    cb = Map.update(state.current_block, :text, text, &(&1 <> text))
    {events ++ [{:text_delta, text}], %{state | current_block: cb}}
  end

  defp handle_claude_delta(%{"type" => "thinking_delta", "thinking" => t}, state, events) do
    cb = Map.update(state.current_block, :thinking, t, &(&1 <> t))
    {events ++ [{:thinking_delta, t}], %{state | current_block: cb}}
  end

  defp handle_claude_delta(%{"type" => "signature_delta", "signature" => sig}, state, events) do
    cb = Map.update(state.current_block, :signature, sig, &(&1 <> sig))
    {events, %{state | current_block: cb}}
  end

  defp handle_claude_delta(%{"type" => "input_json_delta", "partial_json" => json}, state, events) do
    {events ++ [{:tool_use_delta, %{partial_json: json}}],
     %{state | tool_json_buf: state.tool_json_buf <> json}}
  end

  defp handle_claude_delta(_, state, events), do: {events, state}

  defp finalize_current_claude_block(%{current_block: %{type: :tool_use} = cb} = state) do
    input =
      case state.tool_json_buf do
        "" ->
          %{}

        raw ->
          case Jason.decode(raw) do
            {:ok, m} -> m
            _ -> %{"_raw" => raw}
          end
      end

    final = %{cb | input: input}
    {final, [{:tool_use_done, %{id: final.id, name: final.name, input: input}}]}
  end

  defp finalize_current_claude_block(%{current_block: cb}), do: {cb, []}

  defp finalize_claude(%{finished?: true}), do: []

  defp finalize_claude(state) do
    base = [model: state.model, usage: state.usage]

    opts =
      case claude_stop_reason(state.stop_reason) do
        nil -> base
        mapped -> Keyword.put(base, :stop_reason, mapped)
      end

    [{:done, Response.from_blocks(state.blocks, opts)}]
  end

  defp claude_stop_reason("end_turn"), do: :end_turn
  defp claude_stop_reason("tool_use"), do: :tool_use
  defp claude_stop_reason("max_tokens"), do: :max_tokens
  defp claude_stop_reason("stop_sequence"), do: :stop_sequence
  defp claude_stop_reason(_), do: nil

  # ── OpenAI chat/completions SSE ──────────────────────────────────────────

  def openai_init_state do
    %{
      content_text: "",
      reasoning_text: "",
      tc_buf: %{},
      usage: %{},
      model: nil,
      finished?: false,
      blocks: []
    }
  end

  def parse_openai(buffer, state) do
    {lines, leftover} = take_sse_lines(buffer)
    {events, new_state} = Enum.reduce(lines, {[], state}, &handle_openai_line/2)
    {events, new_state, leftover}
  end

  defp handle_openai_line(line, {events, state}) do
    case parse_sse_line(line) do
      :skip ->
        {events, state}

      {:data, "[DONE]"} ->
        {events ++ finalize_openai(state), %{state | finished?: true}}

      {:data, json} ->
        case Jason.decode(json) do
          {:ok, evt} -> apply_openai_event(evt, state, events)
          _ -> {events, state}
        end
    end
  end

  defp apply_openai_event(evt, state, events) do
    choice = List.first(evt["choices"] || []) || %{}
    delta = choice["delta"] || %{}
    state = %{state | model: evt["model"] || state.model}

    {events, state} =
      case delta["reasoning_content"] do
        nil ->
          {events, state}

        r ->
          {events ++ [{:thinking_delta, r}], %{state | reasoning_text: state.reasoning_text <> r}}
      end

    {events, state} =
      case delta["content"] do
        nil ->
          {events, state}

        "" ->
          {events, state}

        text ->
          {events ++ [{:text_delta, text}], %{state | content_text: state.content_text <> text}}
      end

    state = Enum.reduce(delta["tool_calls"] || [], state, &accumulate_openai_tc/2)

    state =
      case evt["usage"] do
        u when is_map(u) -> %{state | usage: Map.merge(state.usage, u)}
        _ -> state
      end

    if choice["finish_reason"] do
      {events ++ finalize_openai(state), %{state | finished?: true}}
    else
      {events, state}
    end
  end

  defp accumulate_openai_tc(tc, state) do
    idx = tc["index"] || 0
    function = tc["function"] || %{}
    has_name? = function["name"] not in [nil, ""]

    {idx, buf} =
      cond do
        Map.has_key?(state.tc_buf, idx) ->
          {idx, state.tc_buf[idx]}

        has_name? or state.tc_buf == %{} ->
          {idx, %{id: tc["id"] || "", name: "", args: ""}}

        true ->
          k = state.tc_buf |> Map.keys() |> Enum.max(fn -> 0 end)
          {k, state.tc_buf[k]}
      end

    buf = if has_name?, do: %{buf | name: function["name"]}, else: buf

    buf =
      if function["arguments"], do: %{buf | args: buf.args <> function["arguments"]}, else: buf

    buf = if tc["id"] && buf.id == "", do: %{buf | id: tc["id"]}, else: buf
    %{state | tc_buf: Map.put(state.tc_buf, idx, buf)}
  end

  defp finalize_openai(%{finished?: true}), do: []

  defp finalize_openai(state) do
    blocks =
      []
      |> maybe_append(state.reasoning_text != "", %{
        type: :thinking,
        thinking: state.reasoning_text,
        signature: ""
      })
      |> maybe_append(state.content_text != "", %{type: :text, text: state.content_text})
      |> Kernel.++(openai_tool_blocks(state.tc_buf))

    response = Response.from_blocks(blocks, model: state.model, usage: state.usage)
    [{:done, %{response | blocks: blocks}}]
  end

  defp maybe_append(list, false, _), do: list
  defp maybe_append(list, true, item), do: list ++ [item]

  defp openai_tool_blocks(tc_buf) do
    tc_buf
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.flat_map(fn {_idx, tc} -> openai_split_tool(tc) end)
  end

  defp openai_split_tool(%{id: id, name: name, args: args}) do
    case try_parse_tool_args(args) do
      [single] ->
        [%{type: :tool_use, id: id || "", name: name, input: single}]

      multiple ->
        Enum.with_index(multiple, fn input, i ->
          %{type: :tool_use, id: split_id(id, i), name: name, input: input}
        end)
    end
  end

  defp split_id("", i), do: "split_#{i}"
  defp split_id(id, i), do: "#{id}_#{i}"

  defp try_parse_tool_args(""), do: [%{}]

  defp try_parse_tool_args(raw) do
    case Jason.decode(raw) do
      {:ok, m} when is_map(m) ->
        [m]

      _ ->
        parts = Regex.split(~r/(?<=\})(?=\{)/, raw)

        cond do
          length(parts) > 1 -> Enum.map(parts, &decode_part(&1, raw))
          true -> [%{"_raw" => raw}]
        end
    end
  end

  defp decode_part(part, raw) do
    case Jason.decode(part) do
      {:ok, m} -> m
      _ -> %{"_raw" => raw}
    end
  end

  # ── SSE line-level helpers ───────────────────────────────────────────────

  defp take_sse_lines(buffer) do
    case :binary.split(buffer, "\n", [:global]) do
      [] ->
        {[], ""}

      [single] ->
        {[], single}

      parts ->
        {lines, [leftover]} = Enum.split(parts, length(parts) - 1)
        {Enum.map(lines, &String.trim_trailing(&1, "\r")), leftover}
    end
  end

  defp parse_sse_line(""), do: :skip
  defp parse_sse_line(":" <> _), do: :skip
  defp parse_sse_line("data:" <> rest), do: {:data, String.trim_leading(rest)}
  defp parse_sse_line(_), do: :skip
end
