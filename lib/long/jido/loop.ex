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

  ## Scheduling — MANDATORY for any future / recurring / 定时 work

  Whenever the user asks for something to happen **later**, **on a
  schedule**, **every day**, **每天**, **定时**, **定期**, **自动跑**, or
  similar, you MUST use the `schedule_task` tool. Do NOT propose
  `launchd`, `cron`, `crontab`, systemd timers, or background scripts
  for periodicity — the host's `schedule_task` is the right tool and is
  always available.

    - `schedule_task(name, prompt, repeat: "daily", at: "11:00")` —
      every day at 11:00 UTC (convert from local time first).
    - `schedule_task(name, prompt, repeat: "once", next_run_at: "…Z")` —
      one-shot at a specific UTC moment.
    - `list_scheduled_tasks()` / `cancel_scheduled_task(name)` to inspect / remove.

  When fired, the `prompt` is injected back into THIS session as a fresh
  user message — write it as the instruction you want future-you to act
  on (e.g. "Pull today's worklog and submit it"). UTC only; do the
  timezone math yourself before calling.

  ## Web access — tool selection matters

  The web tools serve very different needs; mixing them up is the #1
  source of "I couldn't find anything" failures.

    - **`web_search(query)`** — open-ended discovery: aggregates configured
      search APIs (Tavily / Brave) or SERP scrapers. Returns `{title, url, snippet}`
      hits. Use this whenever you don't already know the canonical URL.

    - **`web_scan(url: …)`** — visit a webpage in a real headless browser
      (Chrome/Obscura via CDP), wait for JS to render, return the
      simplified text + clickable elements. **This is the default for any
      user-facing site**: news articles, blog posts, search-result links,
      docs, social, dashboards, SPAs. After `web_search` hands you a URL,
      go through `web_scan` to actually read it.

    - **`http_fetch(url, method)`** — raw HTTP, no browser. **Reserved for
      machine endpoints**: JSON/XML APIs, RSS feeds, sitemaps, robots.txt,
      health checks. Do NOT point this at content sites — modern publishers
      reject non-browser requests with 401/403 or serve empty JS shells, and
      you'll think the page is dead when it's just blocking you.

    - **`web_execute_js(url, script)`** — open a URL and evaluate a
      custom JS expression against the rendered DOM. Returns whatever
      the expression resolved to (JSON-encode in your script if you
      need structured output). Use this when `web_scan`'s default
      text+links summary isn't enough — e.g. pulling specific table
      rows, JSON-LD, or inline `window` globals. Each call is a fresh
      browser; there is no "current tab" carried between calls.

  Typical flow: `web_search("…")` → pick a URL → `web_scan(url: "…")`.
  If `web_scan` returns `"Obscura not installed yet"`, the binary is
  still downloading in the background — retry in a few seconds.

  ## Memory

  You have two memory tiers, both database-backed:

    - `memory_remember(scope: "session", key, value, kind, importance)`
      saves something tied to this conversation only — current task
      focus, files produced, recent decisions.
    - `memory_remember(scope: "global", …)` saves something that
      survives across every future conversation — stable user facts
      (name, role, time zone), strong preferences, hard rules.

  Pick `kind` from `fact | preference | goal | decision`.
  Pick `importance` 1–5 (3 default) — higher importance wins when
  recall has to rank many matches.

  The most relevant memories are auto-injected at the top of this
  prompt every turn (look for "# Relevant memory" / "# Conversation
  summary"). Only call `memory_recall(query)` when you need to dig
  for something that wasn't auto-surfaced.

  Save proactively when the user states a preference, a goal, or a
  decision worth remembering — but don't echo every passing comment.

  ## Skills (Anthropic-compatible SKILL.md format)

  Skills are pre-curated capability packages (a `SKILL.md` manual plus
  optional `scripts/`, `references/`, `assets/`) living under
  `priv/agent/skills/<name>/` on disk. The filesystem is the source of
  truth — there is no database; an in-memory index is rebuilt from
  disk and kept in sync via a file watcher. Discovery is three-tiered:

    - **L0 — names** are listed above under "# Available skills" every
      turn. Scan them first; a recognisable name is usually enough to
      decide whether to dig further.
    - **L1 — `skill_search(query)`** returns `name + description` for
      skills matching a free-text query. Call this when a name looks
      promising but the description would help confirm.
    - **L2 — `skill_read(name)`** returns the full SKILL.md
      instructions plus `resources_dir` (an absolute path to the
      skill folder). Read the body like a manual page, then **invoke
      the companion scripts yourself with `code_run`** (e.g.
      `python {resources_dir}/scripts/foo.py …`). The runtime does
      not execute skills for you — SKILL.md tells you how.

  ### Installing a new skill mid-conversation

  When you notice a workflow you'll want to reuse, install it as a
  skill on the spot:

    1. `file_write` the SKILL.md to `priv/agent/skills/<kebab-name>/SKILL.md`.
       Required frontmatter: `name` and `description`. Body is plain
       markdown — write it for **future-you** reading it cold.
    2. `file_write` any companion scripts under
       `priv/agent/skills/<kebab-name>/scripts/`.
    3. Call `skill_reindex` to make the new skill visible immediately.
       (The watcher usually picks it up automatically, but `skill_reindex`
       is the safe bet, especially in WSL or under file bursts.)

  """

  # Higher than feels necessary because long ReAct tasks (e.g. "open
  # every link in this newsletter") burn one turn per batch of 4 tool
  # calls; 8 was hitting :max_turns silently halfway through realistic
  # workflows.
  @default_max_turns 20

  # Hard cap on tool_calls the LLM can issue in a single turn. Beyond
  # this, the excess get synthetic "skipped" tool_results telling the
  # model to retry next turn. Prevents runaway batches like "scan 12
  # URLs at once" that blow past the LiveView heartbeat window and
  # exhaust browser-subprocess RAM.
  @max_tool_calls_per_turn 4

  # Concurrency for parallel tool dispatch within a single turn.
  # Per-resource limits (Obscura subprocess concurrency, …) live in
  # the individual tool modules — this only governs how many tools
  # the Loop hands out simultaneously.
  @dispatch_max_concurrency 4
  @dispatch_per_tool_timeout_ms 60_000

  @doc "Default system prompt — exposed so Long.Agent.Server can reuse it."
  def default_system, do: @default_system

  def run(user_prompt, opts) when is_binary(user_prompt) and is_list(opts) do
    tools = Keyword.fetch!(opts, :tools)
    system = Keyword.get(opts, :system, @default_system)
    system_addendum = Keyword.get(opts, :system_addendum)
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)
    on_event = Keyword.get(opts, :on_event, fn _ -> :ok end)
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    tool_ctx = Keyword.get(opts, :tool_context, %{})
    attachments = Keyword.get(opts, :attachments, [])
    history = Keyword.get(opts, :history, [])

    # ReqLLM rejects raw `role: "tool"` strings — use Context builders so
    # we get properly typed Message structs (role: :system / :user /
    # :assistant / :tool) that pass validation. For multimodal input,
    # build a content-parts list with text + image binaries; the LLM
    # provider serializes these in the OpenAI Chat content-parts shape.
    user_msg = build_user_message(user_prompt, attachments)

    system_msg = ReqLLM.Context.system(merge_system(system, system_addendum))
    initial_messages = [system_msg | history] ++ [user_msg]

    display_text = display_text_for(user_prompt, attachments)
    on_message.({:user, user_msg, display_text})

    # Per-run ETS cache shared with tools via `tool_ctx`. WebScan uses
    # it to dedup repeated calls to the same URL within a single user
    # message and to circuit-break URLs that keep failing — same URL
    # failing 2x stops spawning Obscura on attempt 3, returning a
    # synthetic "this URL keeps failing" result so the LLM moves on.
    scan_cache = :ets.new(:scan_cache, [:public, :set])
    tool_ctx = Map.put(tool_ctx, :scan_cache, scan_cache)

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

    try do
      loop(state)
    after
      :ets.delete(scan_cache)
    end
  end

  defp loop(%{turn: turn, max_turns: max} = state) when turn > max do
    state.on_event.({:max_turns, max})
    %{result: :max_turns, text: nil, history: state.messages, turns: max}
  end

  defp loop(state) do
    state.on_event.({:turn_start, state.turn})

    state = inject_btws(state)

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
          ReqLLM.Context.assistant(text || "", tool_calls: req_calls)

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

  # Two-stage dispatch:
  #
  # 1. Split `tool_calls` into the first `@max_tool_calls_per_turn` we
  #    actually execute, plus an overflow tail that gets synthetic
  #    "skipped" tool_results. This caps wall-clock so the LiveView
  #    Bandit transport doesn't time out on an over-ambitious batch.
  #
  # 2. Run the executed portion concurrently via
  #    `Task.Supervisor.async_stream_nolink/4` with a fixed concurrency.
  #    `ordered: true` (the default) preserves the input order so the
  #    returned `tool_results` line up with the assistant's
  #    `tool_calls`. Each task has its own timeout — a single tool
  #    hanging won't stall the whole batch.
  defp dispatch_tools(tool_calls, state) do
    {to_run, overflow} = Enum.split(tool_calls, @max_tool_calls_per_turn)

    run_results =
      Task.Supervisor.async_stream_nolink(
        Long.Agent.TaskSup,
        to_run,
        fn tc -> execute_tool(tc, state) end,
        max_concurrency: @dispatch_max_concurrency,
        timeout: @dispatch_per_tool_timeout_ms,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(to_run)
      |> Enum.map(fn
        {{:ok, {msg, ask}}, _tc} ->
          {msg, ask}

        {{:exit, reason}, tc} ->
          state.on_event.({:tool_done, tc.name, tc.id, {:error, {:task_exit, reason}}})

          {
            ReqLLM.Context.tool_result(
              tc.id,
              Jason.encode!(%{error: "tool execution exited: #{inspect(reason)}"})
            ),
            nil
          }
      end)

    overflow_results = Enum.map(overflow, &skipped_tool_result/1)

    all = run_results ++ overflow_results
    msgs = Enum.map(all, fn {m, _} -> m end)
    ask = Enum.find_value(all, fn {_, a} -> a end)

    {msgs, ask}
  end

  defp skipped_tool_result(tc) do
    payload = %{
      error: "skipped",
      reason:
        "Too many tool_calls in this turn (cap = #{@max_tool_calls_per_turn}). " <>
          "Issue this call again in the next turn.",
      tool_name: tc.name
    }

    {ReqLLM.Context.tool_result(tc.id, Jason.encode!(payload)), nil}
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

    ask =
      case result do
        {:ok, %{ask_user: true} = payload} -> payload
        _ -> nil
      end

    {ReqLLM.Context.tool_result(id, format_result(result)), ask}
  end

  # `String.to_existing_atom/1` because the schema's atom keys are
  # already in the atom table; hallucinated keys are dropped rather
  # than leaked into it.
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

  defp format_result({:ok, payload}) when is_map(payload),
    do: payload |> Long.Util.Utf8.sanitize() |> Jason.encode!()

  defp format_result({:ok, payload}), do: inspect(payload)

  defp format_result({:error, e}) when is_binary(e),
    do: Jason.encode!(%{error: Long.Util.Utf8.sanitize(e)})

  defp format_result({:error, e}), do: Jason.encode!(%{error: inspect(e)})

  defp merge_system(base, nil), do: base
  defp merge_system(base, ""), do: base

  defp merge_system(base, addendum) when is_binary(addendum) do
    base <> "\n\n# Conversation summary so far (carry-forward context)\n\n" <> addendum
  end

  # Build a `ReqLLM.Message` for the user turn. Plain string when no
  # attachments; a content-parts list mixing text + image binaries when
  # the caller passes image paths. Non-existent or unreadable images
  # are silently dropped (we'd rather lose a part than crash the loop).
  defp build_user_message(text, []) when is_binary(text), do: ReqLLM.Context.user(text)

  defp build_user_message(text, attachments) when is_list(attachments) do
    image_parts =
      attachments
      |> Enum.filter(&image_path?/1)
      |> Enum.flat_map(&read_image_part/1)

    case image_parts do
      [] ->
        ReqLLM.Context.user(text)

      parts ->
        ReqLLM.Context.user([ReqLLM.Message.ContentPart.text(text || "") | parts])
    end
  end

  defp display_text_for(text, []), do: text

  defp display_text_for(text, attachments) do
    image_names =
      attachments
      |> Enum.filter(&image_path?/1)
      |> Enum.map(&Path.basename/1)

    case image_names do
      [] -> text
      names -> "#{text}\n[附件: #{Enum.join(names, ", ")}]"
    end
  end

  @image_exts ~w(.jpg .jpeg .png .gif .webp .bmp)

  defp image_path?(path) when is_binary(path) do
    Path.extname(path) |> String.downcase() |> then(&(&1 in @image_exts))
  end

  defp image_path?(_), do: false

  defp read_image_part(path) do
    case File.read(path) do
      {:ok, bytes} -> [ReqLLM.Message.ContentPart.image(bytes, mime_for(path))]
      _ -> []
    end
  end

  @mime_by_ext %{
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".png" => "image/png",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".bmp" => "image/bmp"
  }

  defp mime_for(path) do
    ext = path |> Path.extname() |> String.downcase()
    Map.get(@mime_by_ext, ext, "application/octet-stream")
  end

  # Consume any `/btw` notes the user queued while this loop was
  # mid-flight (see `Long.Agent.Activity.add_btw/2`) and append them as
  # user-role messages so the LLM picks them up on the next call.
  defp inject_btws(state) do
    sid = state.tool_ctx[:session_id]

    if is_binary(sid) do
      case Long.Agent.Activity.take_btws(sid) do
        [] ->
          state

        notes ->
          extras = Enum.map(notes, &ReqLLM.Context.user("[补充] " <> &1))
          %{state | messages: state.messages ++ extras}
      end
    else
      state
    end
  end
end
