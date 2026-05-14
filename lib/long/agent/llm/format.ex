defmodule Long.Agent.LLM.Format do
  @moduledoc """
  Conversions between the canonical Anthropic content-block message format and
  OpenAI chat-completion message format. Ports `llmcore._msgs_claude2oai` and
  `_fix_messages`.

  Canonical message shape:

      %{role: :user | :assistant | :system | :tool,
        content: [%{type: :text, text: ...} | %{type: :tool_use, ...} | %{type: :tool_result, ...} | %{type: :thinking, ...}]}

  Strings are also accepted in `content` and are auto-wrapped into a single text
  block.
  """

  def to_claude_messages(messages) do
    messages
    |> Enum.map(&normalize_message/1)
    |> fix_messages()
    |> drop_unsigned_thinking()
  end

  def to_openai_messages(messages) do
    messages
    |> Enum.map(&normalize_message/1)
    |> fix_messages()
    |> Enum.flat_map(&claude_msg_to_oai/1)
  end

  defp normalize_message(%{role: role, content: c} = m) when is_binary(c) do
    %{m | role: role_atom(role), content: [%{type: :text, text: c}]}
  end

  defp normalize_message(%{role: role, content: c} = m) when is_list(c) do
    %{m | role: role_atom(role), content: Enum.map(c, &normalize_block/1)}
  end

  defp normalize_message(%{role: role} = m) do
    %{m | role: role_atom(role), content: []}
  end

  defp role_atom(r) when is_atom(r), do: r

  defp role_atom(r) when is_binary(r) do
    case String.downcase(r) do
      "user" -> :user
      "assistant" -> :assistant
      "system" -> :system
      "tool" -> :tool
      _ -> :user
    end
  end

  defp normalize_block(%{type: _} = b), do: b
  defp normalize_block(%{"type" => _} = b), do: atomize_block(b)
  defp normalize_block(text) when is_binary(text), do: %{type: :text, text: text}

  defp atomize_block(%{"type" => type} = b) do
    base = %{type: String.to_atom(type)}

    Enum.reduce(b, base, fn
      {"type", _}, acc -> acc
      {k, v}, acc when is_binary(k) -> Map.put(acc, String.to_atom(k), v)
      {k, v}, acc -> Map.put(acc, k, v)
    end)
  end

  # ── _fix_messages: pair tool_use/tool_result, merge same-role runs ───────

  defp fix_messages([]), do: []

  defp fix_messages(messages) do
    messages
    |> Enum.reduce([], &merge_or_append/2)
    |> Enum.reverse()
    |> drop_until_user()
  end

  defp merge_or_append(msg, []), do: [msg]

  defp merge_or_append(%{role: r} = msg, [%{role: r} = prev | rest]) do
    merged = %{prev | content: prev.content ++ [%{type: :text, text: "\n"}] ++ msg.content}
    [merged | rest]
  end

  defp merge_or_append(%{role: :user} = msg, [%{role: :assistant} = prev | _] = acc) do
    uses = for %{type: :tool_use, id: id} <- prev.content, id != "", do: id
    has = for %{type: :tool_result, tool_use_id: id} <- msg.content, into: MapSet.new(), do: id
    missing = Enum.reject(uses, &MapSet.member?(has, &1))

    msg =
      if missing == [] do
        msg
      else
        synthetic =
          for id <- missing, do: %{type: :tool_result, tool_use_id: id, content: "(error)"}

        %{msg | content: synthetic ++ msg.content}
      end

    [msg | acc]
  end

  defp merge_or_append(msg, acc), do: [msg | acc]

  defp drop_until_user(messages) do
    Enum.drop_while(messages, &(&1.role != :user))
  end

  # ── Strip unsigned `thinking` blocks (Claude rejects them) ──────────────

  defp drop_unsigned_thinking(messages) do
    Enum.map(messages, fn m ->
      content =
        Enum.reject(m.content, fn b ->
          b[:type] == :thinking and b[:signature] in [nil, ""]
        end)

      %{m | content: content}
    end)
  end

  # ── claude → openai per-message conversion ──────────────────────────────

  defp claude_msg_to_oai(%{role: :assistant, content: blocks}) do
    {text_parts, tool_calls, reasoning} = split_assistant_blocks(blocks)

    base = %{"role" => "assistant"}
    base = if reasoning != "", do: Map.put(base, "reasoning_content", reasoning), else: base

    base =
      cond do
        text_parts != [] -> Map.put(base, "content", text_parts)
        tool_calls == [] -> Map.put(base, "content", ".")
        true -> base
      end

    base = if tool_calls != [], do: Map.put(base, "tool_calls", tool_calls), else: base
    [base]
  end

  defp claude_msg_to_oai(%{role: :user, content: blocks}) do
    {text_parts, trailing} = split_user_blocks(blocks)

    head = if text_parts != [], do: [%{"role" => "user", "content" => text_parts}], else: []
    head ++ trailing
  end

  defp claude_msg_to_oai(%{role: :system, content: blocks}) do
    text = Enum.map_join(blocks, "\n", &(&1[:text] || ""))
    [%{"role" => "system", "content" => text}]
  end

  defp claude_msg_to_oai(%{role: role, content: blocks}) do
    text = Enum.map_join(blocks, "\n", &(&1[:text] || ""))
    [%{"role" => Atom.to_string(role), "content" => text}]
  end

  defp split_assistant_blocks(blocks) do
    Enum.reduce(blocks, {[], [], ""}, fn
      %{type: :thinking, thinking: t}, {texts, tcs, _r} when t != "" ->
        {texts, tcs, t}

      %{type: :text, text: t}, {texts, tcs, r} when t != "" ->
        {texts ++ [%{"type" => "text", "text" => t}], tcs, r}

      %{type: :tool_use} = b, {texts, tcs, r} ->
        tc = %{
          "id" => b[:id] || "",
          "type" => "function",
          "function" => %{
            "name" => b[:name] || "",
            "arguments" => Jason.encode!(b[:input] || %{})
          }
        }

        {texts, tcs ++ [tc], r}

      _, acc ->
        acc
    end)
  end

  defp split_user_blocks(blocks) do
    Enum.reduce(blocks, {[], []}, fn
      %{type: :tool_result, tool_use_id: id, content: c}, {texts, tail} ->
        tail_msg = %{"role" => "tool", "tool_call_id" => id, "content" => stringify(c)}
        # any pending texts go first as a regular user message
        emitted =
          if texts == [], do: [], else: [%{"role" => "user", "content" => texts}]

        {[], tail ++ emitted ++ [tail_msg]}

      %{type: :text, text: t}, {texts, tail} when t != "" ->
        {texts ++ [%{"type" => "text", "text" => t}], tail}

      _, acc ->
        acc
    end)
  end

  defp stringify(c) when is_binary(c), do: c

  defp stringify(c) when is_list(c) do
    c
    |> Enum.filter(&match?(%{type: :text}, &1))
    |> Enum.map_join("\n", &(&1[:text] || ""))
  end

  defp stringify(c), do: inspect(c)
end
