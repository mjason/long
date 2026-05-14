defmodule Long.Jido.Loop do
  @moduledoc """
  Phase B v1 — a self-contained ReAct loop built on `Long.Jido.LLMCall`
  (custom ReqLLM wrapper) + `Jido.Action` tools.

  Side-by-side with the existing `Long.Agent.Loop`; SessionRunner is **not**
  swapped over yet. Use this from iex / tests to compare behaviour.

      iex> Long.Jido.Loop.run("帮我看下 hacker news 前 3 条",
      ...>   tools: [Long.Jido.Tools.HttpFetch], llm_alias: "聆思")

  Returns `%{result: :done | :max_turns, text, history, turns}`.
  """

  alias Long.Jido.LLMCall

  @default_system """
  You are a helpful agent. Use the provided tools to fulfil the user's
  request. When a tool returns data, read it carefully and answer in the
  user's language.
  """

  @default_max_turns 8

  def run(user_prompt, opts) when is_binary(user_prompt) and is_list(opts) do
    tools = Keyword.fetch!(opts, :tools)
    system = Keyword.get(opts, :system, @default_system)
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)
    on_event = Keyword.get(opts, :on_event, fn _ -> :ok end)
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    tool_ctx = Keyword.get(opts, :tool_context, %{})

    # ReqLLM rejects raw `role: "tool"` strings — use Context builders so
    # we get properly typed Message structs (role: :system / :user /
    # :assistant / :tool) that pass validation.
    user_msg = ReqLLM.Context.user(user_prompt)
    initial_messages = [ReqLLM.Context.system(system), user_msg]

    on_message.({:user, user_msg, user_prompt})

    callbacks =
      Map.new(tools, fn mod -> {mod.name(), fn args -> Jido.Exec.run(mod, args, tool_ctx) end} end)

    llm_opts =
      opts
      |> Keyword.take([:llm_alias, :max_tokens, :temperature])
      |> Keyword.put(:tool_callbacks, callbacks)

    state = %{
      messages: initial_messages,
      tools: tools,
      llm_opts: llm_opts,
      tool_ctx: tool_ctx,
      max_turns: max_turns,
      turn: 1,
      on_event: on_event,
      on_message: on_message
    }

    loop(state)
  end

  defp loop(%{turn: turn, max_turns: max} = state) when turn > max do
    state.on_event.({:max_turns, max})
    %{result: :max_turns, text: nil, history: state.messages, turns: max}
  end

  defp loop(state) do
    state.on_event.({:turn_start, state.turn})

    case LLMCall.call(state.messages, state.tools, state.llm_opts) do
      {:ok, %{type: :final_answer, text: text, usage: usage} = resp} ->
        msg = ReqLLM.Context.assistant(text)
        state.on_message.({:assistant, msg, resp})
        state.on_event.({:final, text, usage})
        %{result: :done, text: text, history: state.messages ++ [msg], turns: state.turn}

      {:ok, %{type: :tool_calls, tool_calls: tool_calls, text: text, usage: usage} = resp} ->
        state.on_event.({:tool_calls, tool_calls, usage})

        req_calls =
          Enum.map(tool_calls, fn tc ->
            ReqLLM.ToolCall.new(tc.id, tc.name, Jason.encode!(tc.arguments))
          end)

        assistant_msg =
          ReqLLM.Context.assistant(
            if(text == "", do: nil, else: text),
            tool_calls: req_calls
          )

        state.on_message.({:assistant, assistant_msg, resp})

        # Execute each tool. ask_user short-circuits the whole loop.
        {tool_msgs, ask_user} = dispatch_tools(tool_calls, state)

        Enum.each(tool_msgs, fn m -> state.on_message.({:tool, m, nil}) end)

        case ask_user do
          nil ->
            new_messages = state.messages ++ [assistant_msg | tool_msgs]
            loop(%{state | messages: new_messages, turn: state.turn + 1})

          payload ->
            state.on_event.({:ask_user, payload})

            %{
              result: :asked_user,
              text: text,
              history: state.messages ++ [assistant_msg | tool_msgs],
              turns: state.turn,
              ask_user: payload
            }
        end

      {:error, reason} ->
        state.on_event.({:error, reason})
        %{result: :error, text: nil, history: state.messages, turns: state.turn, error: reason}
    end
  end

  defp dispatch_tools(tool_calls, state) do
    {rev_msgs, ask} =
      Enum.reduce(tool_calls, {[], nil}, fn tc, {acc, ask} ->
        {msg, ask_payload} = execute_tool(tc, state)
        {[msg | acc], ask || ask_payload}
      end)

    {Enum.reverse(rev_msgs), ask}
  end

  defp execute_tool(%{id: id, name: name, arguments: args}, state) do
    state.on_event.({:tool_start, name, args, id})

    mod = Enum.find(state.tools, &(&1.name() == name))

    result =
      if is_nil(mod) do
        {:error, "unknown tool: #{name}"}
      else
        Jido.Exec.run(mod, safe_atomize_keys(args), state.tool_ctx)
      end

    state.on_event.({:tool_done, name, id, result})

    ask = detect_ask_user(result)
    {ReqLLM.Context.tool_result(id, format_result(result)), ask}
  end

  defp detect_ask_user({:ok, %{ask_user: true} = payload}), do: payload
  defp detect_ask_user(_), do: nil

  # LLM-supplied arg keys go through `String.to_existing_atom/1`. Every
  # known schema key is already an atom from compile time, so valid args
  # convert cleanly; hallucinated keys raise `ArgumentError` and we drop
  # them — no `String.to_atom/1`, no atom-table leak.
  defp safe_atomize_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {k, v}, acc when is_binary(k) ->
        try do
          Map.put(acc, String.to_existing_atom(k), v)
        rescue
          ArgumentError -> acc
        end

      {k, v}, acc ->
        Map.put(acc, k, v)
    end)
  end

  defp safe_atomize_keys(other), do: other

  defp format_result({:ok, payload}) when is_map(payload), do: Jason.encode!(payload)
  defp format_result({:ok, payload}), do: inspect(payload)
  defp format_result({:error, e}) when is_binary(e), do: Jason.encode!(%{error: e})
  defp format_result({:error, e}), do: Jason.encode!(%{error: inspect(e)})
end
