defmodule Long.Agent.Loop do
  @moduledoc """
  Stream-driven agent loop. Port of `agent_runner_loop` in `agent_loop.py`.

  Yields tagged events the caller can pipe straight into a LiveView or
  terminal renderer:

  - `{:turn_start, turn}`
  - `{:llm_chunk, text}` / `{:llm_thinking, text}`
  - `{:llm_done, %Response{}}` — after the model finishes a turn
  - `{:tool_start, %{name, args, index, count}}`
  - `{:tool_output, text}` — streamed tool stdout
  - `{:tool_done, %{name, data}}`
  - `{:ask_user, %{question, candidates}}` — terminal; loop halts
  - `{:done, %{reason: :no_tool_call | :exited | :max_turns | :llm_error, …}}` — terminal

  ## Run options

  - `:backend` (required) — a `%Long.Agent.LLM.Backend.*{}` struct
  - `:messages` — initial canonical messages list (defaults to a single user
    msg built from `:user`)
  - `:user` — convenience: when `:messages` is absent, builds one
    `[%{role: :user, content: user}]`
  - `:system` — system prompt
  - `:tools` — list of tool modules (defaults to the six Phase 2 tools)
  - `:session_id` — Phase 0 session uuid for L1 persistence
  - `:cwd` — agent working directory (defaults to `priv/agent/temp`)
  - `:max_turns` — default 40
  """

  alias Long.Agent.{LLM, Memory, StepOutcome, ToolContext}

  alias Long.Agent.Tools.{
    AskUser,
    CodeRun,
    FileRead,
    FileWrite,
    FilePatch,
    MemorySearch,
    MemoryUpsert,
    StartLongTermUpdate,
    UpdateWorkingCheckpoint,
    WebExecuteJs,
    WebScan
  }

  @default_tools [
    CodeRun,
    FileRead,
    FileWrite,
    FilePatch,
    UpdateWorkingCheckpoint,
    MemorySearch,
    MemoryUpsert,
    StartLongTermUpdate,
    WebScan,
    WebExecuteJs,
    AskUser
  ]
  @default_max_turns 40
  @recv_timeout 120_000

  defstruct [
    :backend,
    :messages,
    :system,
    :tool_registry,
    :tool_schema,
    :ctx_template,
    :on_message,
    turn: 0,
    max_turns: @default_max_turns,
    halted?: false,
    phase: :start_turn,
    llm_iter: nil,
    llm_response: nil,
    pending_tools: [],
    tool_iter: nil,
    current_tool: nil,
    tool_index: 0,
    tool_count: 0,
    tool_results: [],
    next_prompts: MapSet.new(),
    exit_reason: nil
  ]

  def run(opts) do
    Stream.resource(
      fn -> init_state(opts) end,
      &step/1,
      &cleanup/1
    )
  end

  defp init_state(opts) do
    tools = Keyword.get(opts, :tools, @default_tools)
    registry = Map.new(tools, &{&1.name(), &1})

    messages =
      cond do
        Keyword.has_key?(opts, :messages) -> Keyword.fetch!(opts, :messages)
        user = Keyword.get(opts, :user) -> [%{role: :user, content: user}]
        true -> raise ArgumentError, "Loop.run needs :messages or :user"
      end

    cwd =
      Keyword.get_lazy(opts, :cwd, fn ->
        Application.get_env(:long, Long.Agent, [])[:temp_root] ||
          Path.expand("priv/agent/temp", File.cwd!())
      end)

    File.mkdir_p!(cwd)
    session_id = Keyword.get(opts, :session_id)
    system = resolve_system(Keyword.get(opts, :system), session_id, opts)

    %__MODULE__{
      backend: Keyword.fetch!(opts, :backend),
      messages: messages,
      system: system,
      tool_registry: registry,
      tool_schema: Enum.map(tools, & &1.schema()),
      max_turns: Keyword.get(opts, :max_turns, @default_max_turns),
      on_message: Keyword.get(opts, :on_message),
      ctx_template: %ToolContext{
        session_id: session_id,
        cwd: cwd,
        memory_root:
          Application.get_env(:long, Long.Agent, [])[:memory_root] ||
            Path.expand("priv/agent/memory", File.cwd!())
      }
    }
  end

  defp resolve_system(explicit, session_id, opts) when is_binary(explicit) and explicit != "" do
    if Keyword.get(opts, :compose_memory_into_system?, true) and session_id != nil do
      Memory.build_system_prompt(session_id, prefix: explicit)
    else
      explicit
    end
  end

  defp resolve_system(_explicit, session_id, opts) do
    if Keyword.get(opts, :compose_memory_into_system?, true) and session_id != nil do
      case Memory.build_system_prompt(session_id) do
        "" -> nil
        prompt -> prompt
      end
    else
      nil
    end
  end

  defp cleanup(%__MODULE__{llm_iter: lit, tool_iter: tit}) do
    close_iter(lit)
    close_iter(tit)
  end

  defp cleanup(_), do: :ok

  # ── Phase dispatch ────────────────────────────────────────────────────────

  defp step(%__MODULE__{halted?: true} = s), do: {:halt, s}

  defp step(%__MODULE__{turn: t, max_turns: max} = s) when t >= max do
    {[{:done, %{reason: :max_turns, turn: t}}], %{s | halted?: true}}
  end

  defp step(%__MODULE__{phase: :start_turn} = s), do: start_turn(s)
  defp step(%__MODULE__{phase: :read_llm} = s), do: read_llm(s)
  defp step(%__MODULE__{phase: :dispatch_tool} = s), do: dispatch_tool(s)
  defp step(%__MODULE__{phase: :continue_or_end} = s), do: continue_or_end(s)

  defp start_turn(s) do
    turn = s.turn + 1

    stream =
      LLM.chat(s.backend, s.messages,
        tools: s.tool_schema,
        system: s.system
      )

    iter = wrap_stream(stream)
    {[{:turn_start, turn}], %{s | turn: turn, phase: :read_llm, llm_iter: iter}}
  end

  defp read_llm(%__MODULE__{llm_iter: it} = s) do
    case next_iter(it) do
      {:ok, {:text_delta, text}} ->
        {[{:llm_chunk, text}], s}

      {:ok, {:thinking_delta, text}} ->
        {[{:llm_thinking, text}], s}

      {:ok, {:done, response}} ->
        close_iter(it)
        assistant_msg = %{role: :assistant, content: response.blocks, turn: s.turn}
        notify_message(s, assistant_msg)
        s = %{s | messages: s.messages ++ [assistant_msg]}

        cond do
          response.tool_calls == [] ->
            {[{:llm_done, response}, {:done, %{reason: :no_tool_call, response: response}}],
             %{s | halted?: true, llm_iter: nil, llm_response: response}}

          true ->
            {[{:llm_done, response}],
             %{
               s
               | llm_iter: nil,
                 llm_response: response,
                 pending_tools: response.tool_calls,
                 tool_index: 0,
                 tool_count: length(response.tool_calls),
                 tool_results: [],
                 next_prompts: MapSet.new(),
                 exit_reason: nil,
                 phase: :dispatch_tool
             }}
        end

      {:ok, {:error, e}} ->
        close_iter(it)
        {[{:done, %{reason: :llm_error, error: e}}], %{s | halted?: true}}

      :halt ->
        {[{:done, %{reason: :stream_closed}}], %{s | halted?: true}}

      _ ->
        {[], s}
    end
  end

  defp dispatch_tool(%__MODULE__{pending_tools: []} = s) do
    {[], %{s | phase: :continue_or_end}}
  end

  defp dispatch_tool(%__MODULE__{tool_iter: nil, pending_tools: [tc | _]} = s) do
    case Map.get(s.tool_registry, tc.name) do
      nil ->
        outcome =
          StepOutcome.cont(
            %{"status" => "error", "msg" => "unknown tool: #{tc.name}"},
            "Unknown tool `#{tc.name}` — pick one from the tools list."
          )

        s
        |> accumulate(tc, outcome)
        |> drop_pending()
        |> bump_tool_index()
        |> emit_tool_done(tc, outcome)

      mod ->
        ctx = %{
          s.ctx_template
          | tool_index: s.tool_index,
            tool_count: s.tool_count,
            response: s.llm_response,
            turn: s.turn
        }

        iter = wrap_stream(mod.run(tc.input, ctx))

        {[
           {:tool_start,
            %{
              id: tc.id,
              name: tc.name,
              args: tc.input,
              index: s.tool_index,
              count: s.tool_count
            }}
         ], %{s | tool_iter: iter, current_tool: tc}}
    end
  end

  defp dispatch_tool(%__MODULE__{tool_iter: it, current_tool: tc} = s) do
    case next_iter(it) do
      {:ok, {:output, text}} ->
        {[{:tool_output, text}], s}

      {:ok, {:outcome, %StepOutcome{} = outcome}} ->
        close_iter(it)

        s
        |> accumulate(tc, outcome)
        |> drop_pending()
        |> bump_tool_index()
        |> Map.merge(%{tool_iter: nil, current_tool: nil})
        |> emit_tool_done(tc, outcome)

      :halt ->
        close_iter(it)
        outcome = StepOutcome.cont(%{"status" => "error", "msg" => "tool stream halted"})

        s
        |> accumulate(tc, outcome)
        |> drop_pending()
        |> bump_tool_index()
        |> Map.merge(%{tool_iter: nil, current_tool: nil})
        |> emit_tool_done(tc, outcome)

      _ ->
        {[], s}
    end
  end

  defp emit_tool_done(s, tc, outcome) do
    {[
       {:tool_done, %{id: tc.id, name: tc.name, data: outcome.data, exit?: outcome.should_exit?}}
     ], s}
  end

  defp continue_or_end(%__MODULE__{exit_reason: %{kind: :exit_with, data: data}} = s) do
    case data do
      %{"question" => _} ->
        {[{:ask_user, data}, {:done, %{reason: :asked_user, data: data}}], %{s | halted?: true}}

      _ ->
        {[{:done, %{reason: :exited, data: data}}], %{s | halted?: true}}
    end
  end

  defp continue_or_end(%__MODULE__{next_prompts: prompts} = s) do
    if MapSet.size(prompts) == 0 do
      {[{:done, %{reason: :task_done}}], %{s | halted?: true}}
    else
      next_prompt =
        prompts |> MapSet.to_list() |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n")

      user_msg = build_next_user_message(s.tool_results, next_prompt, s.turn + 1)
      notify_message(s, user_msg)

      {[],
       %{
         s
         | messages: s.messages ++ [user_msg],
           tool_results: [],
           next_prompts: MapSet.new(),
           exit_reason: nil,
           pending_tools: [],
           llm_response: nil,
           tool_count: 0,
           tool_index: 0,
           phase: :start_turn
       }}
    end
  end

  # ── Accumulation helpers ─────────────────────────────────────────────────

  defp accumulate(s, tc, %StepOutcome{should_exit?: true, data: data}) do
    %{
      s
      | exit_reason: %{kind: :exit_with, data: data},
        tool_results:
          s.tool_results ++
            [%{type: :tool_result, tool_use_id: tc.id, content: serialize_tool_result(data)}]
    }
  end

  defp accumulate(s, tc, %StepOutcome{} = outcome) do
    tool_result =
      if outcome.data != nil and tc.name != "no_tool" do
        [%{type: :tool_result, tool_use_id: tc.id, content: serialize_tool_result(outcome.data)}]
      else
        []
      end

    next =
      if outcome.next_prompt in [nil, ""],
        do: s.next_prompts,
        else: MapSet.put(s.next_prompts, outcome.next_prompt)

    exit_reason =
      if outcome.next_prompt in [nil, ""],
        do: s.exit_reason || %{kind: :task_done},
        else: s.exit_reason

    %{
      s
      | tool_results: s.tool_results ++ tool_result,
        next_prompts: next,
        exit_reason: exit_reason
    }
  end

  defp drop_pending(%{pending_tools: [_ | rest]} = s), do: %{s | pending_tools: rest}
  defp drop_pending(s), do: s

  defp bump_tool_index(s), do: %{s | tool_index: s.tool_index + 1}

  defp serialize_tool_result(s) when is_binary(s), do: s
  defp serialize_tool_result(other), do: Jason.encode!(other)

  defp build_next_user_message(tool_results, next_prompt, turn) do
    text_blocks = if next_prompt == "", do: [], else: [%{type: :text, text: next_prompt}]
    %{role: :user, content: tool_results ++ text_blocks, turn: turn}
  end

  defp notify_message(%__MODULE__{on_message: nil}, _msg), do: :ok

  defp notify_message(%__MODULE__{on_message: cb}, msg) when is_function(cb, 1) do
    cb.(msg)
    :ok
  end

  # ── Stream → polling iterator bridge ─────────────────────────────────────

  defp wrap_stream(stream) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        Enum.each(stream, fn ev -> send(parent, {ref, :ev, ev}) end)
        send(parent, {ref, :done})
      end)

    %{ref: ref, task: task}
  end

  defp next_iter(%{ref: ref}) do
    receive do
      {^ref, :ev, ev} -> {:ok, ev}
      {^ref, :done} -> :halt
    after
      @recv_timeout -> {:ok, {:error, :iter_timeout}}
    end
  end

  defp close_iter(nil), do: :ok
  defp close_iter(%{task: task}), do: Task.shutdown(task, :brutal_kill)
end
