defmodule Mix.Tasks.Long.PreviewRequest do
  @shortdoc "Dump the exact system prompt + tools + messages that would be sent to the LLM"

  @moduledoc """
  Reconstructs the prompt that `Long.Agent.Server.start_llm_turn/4`
  would build for a given session_id and hypothetical user message,
  without actually firing the LLM. Lets you verify the prompt the
  model sees matches what you intended.

  ## Usage

      mix long.preview_request <session_id> <user message>

  Or use the latest session in the local DB:

      mix long.preview_request --latest "你内置了什么能力"

  ## What it prints

  - System prompt (full, with tool inventory, GraphQL cheatsheet,
    addendum, session_id substituted)
  - Tool list (names + Jido.AI.ToolAdapter shape)
  - Conversation history loaded for this session
  - The synthetic user message that would be appended

  Useful when behavior on prod differs from expectations: compare the
  printed prompt to what you THINK the model is seeing.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _} = OptionParser.parse(args, switches: [latest: :boolean, json: :boolean])

    {session_id, text} = resolve_args(opts, positional)

    {:ok, session} = Long.Agent.get_session(session_id)

    bundle = build_request_bundle(session, text)

    if opts[:json] do
      IO.puts(Jason.encode!(bundle, pretty: true))
    else
      render(bundle)
    end
  end

  defp resolve_args(opts, positional) do
    case {opts[:latest], positional} do
      {true, [text]} ->
        {latest_session_id!(), text}

      {nil, [sid, text]} ->
        {sid, text}

      _ ->
        Mix.raise(
          "Usage:\n  mix long.preview_request <session_id> <text>\n  mix long.preview_request --latest <text>"
        )
    end
  end

  defp latest_session_id! do
    case Long.Agent.list_sessions() do
      {:ok, []} -> Mix.raise("no sessions in the local DB")
      {:ok, list} ->
        list
        |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
        |> hd()
        |> Map.fetch!(:id)
    end
  end

  # Mirror of Long.Agent.Server.start_llm_turn/4 prompt assembly, but
  # without spawning anything or mutating state.
  defp build_request_bundle(session, text) do
    alias_name = session.llm_alias || Long.Agent.default_llm_alias()
    tools = Long.Jido.SessionRunner.default_tools()

    %{system_addendum: summary_addendum, messages: history} =
      Long.Jido.History.load_or_compress(session.id, alias_name)

    memory_addendum =
      text
      |> Long.Agent.Memory.Recall.recall(session_id: session.id, limit: 8, bump: false)
      |> Long.Agent.Memory.Recall.format_for_prompt()

    addendum =
      [summary_addendum, memory_addendum, Long.Agent.Skill.Store.list_names_for_prompt()]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join("\n\n")

    system_text =
      [
        Long.Agent.ToolInventory.render(tools),
        Long.Jido.Loop.default_system() |> String.replace("{{session_id}}", session.id),
        addendum
      ]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join("\n\n")

    %{
      session_id: session.id,
      llm_alias: alias_name,
      system_text: system_text,
      system_chars: String.length(system_text),
      tool_names: Enum.map(tools, & &1.name()),
      history_count: length(history),
      history: Enum.map(history, &message_summary/1),
      user_message: text
    }
  end

  defp message_summary(%ReqLLM.Message{role: role, content: parts}) do
    text =
      case parts do
        list when is_list(list) ->
          Enum.map_join(list, "", fn
            %{type: :text, text: t} -> t
            _ -> ""
          end)

        bin when is_binary(bin) ->
          bin

        _ ->
          ""
      end

    %{role: role, text: String.slice(text, 0, 200)}
  end

  defp render(b) do
    IO.puts(IO.ANSI.cyan() <> "=== Request preview for session #{b.session_id} ===" <> IO.ANSI.reset())
    IO.puts("alias            : #{b.llm_alias}")
    IO.puts("system_chars     : #{b.system_chars} (~#{div(b.system_chars, 4)} tokens estimate)")
    IO.puts("tool_count       : #{length(b.tool_names)}")
    IO.puts("tools            : #{Enum.join(b.tool_names, ", ")}")
    IO.puts("history_count    : #{b.history_count}")
    IO.puts("")
    IO.puts(IO.ANSI.yellow() <> "--- SYSTEM TEXT ---" <> IO.ANSI.reset())
    IO.puts(b.system_text)
    IO.puts("")
    IO.puts(IO.ANSI.yellow() <> "--- HISTORY (truncated to 200 chars each) ---" <> IO.ANSI.reset())

    Enum.each(b.history, fn %{role: r, text: t} ->
      IO.puts("  [#{r}] #{t}")
    end)

    IO.puts("")
    IO.puts(IO.ANSI.yellow() <> "--- HYPOTHETICAL USER MESSAGE ---" <> IO.ANSI.reset())
    IO.puts("  #{b.user_message}")
  end
end
