defmodule LongWeb.AgentLive.Chat do
  @moduledoc """
  Phase 6 — the LiveView the user interacts with. Subscribes to the
  session's PubSub topic, renders streaming LLM output and tool runs in
  real time, and surfaces the L1/L2 memory in the right rail.
  """

  use LongWeb, :live_view

  alias Long.Agent
  alias Long.SessionRunner

  @impl true
  def mount(params, _session, socket) do
    {:ok, session_id} = ensure_session(params)
    if connected?(socket), do: SessionRunner.subscribe(session_id)

    {:ok,
     socket
     |> assign(:page_title, "Agent")
     |> assign(:session_id, session_id)
     |> assign(:session, load_session(session_id))
     |> assign(:messages, load_messages(session_id))
     |> assign(:streaming, nil)
     |> assign(:loop_running?, false)
     |> assign(:available_llms, list_llms())
     |> assign(:checkpoint, load_checkpoint(session_id))
     |> assign(:global_memory, load_global_memory())
     |> assign(:ask_user, nil)
     |> assign(:sessions, list_sessions())
     |> assign(:sidebar_open?, true)
     |> assign(:memory_open?, true)}
  end

  @impl true
  def handle_event("submit", %{"input" => text}, socket) do
    case String.trim(text) do
      "" ->
        {:noreply, socket}

      trimmed ->
        SessionRunner.send_user_message(socket.assigns.session_id, trimmed)

        {:noreply,
         socket
         |> assign(:loop_running?, true)
         |> assign(:streaming, %{text: "", thinking: "", tool_runs: []})
         |> push_event("agent:clear-composer", %{})}
    end
  end

  def handle_event("new_session", _, socket) do
    {:ok, sess} = Agent.start_session(%{title: "untitled"})
    {:noreply, push_navigate(socket, to: ~p"/chat/#{sess.id}")}
  end

  def handle_event("switch_session", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/chat/#{id}")}
  end

  def handle_event("set_llm", %{"alias" => alias_str}, socket) do
    new_alias = if alias_str == "", do: nil, else: alias_str
    {:ok, sess} = Agent.update_session(socket.assigns.session, %{llm_alias: new_alias})
    {:noreply, assign(socket, :session, sess)}
  end

  def handle_event("answer_ask_user", %{"answer" => answer}, socket) do
    SessionRunner.send_user_message(socket.assigns.session_id, answer)
    {:noreply, assign(socket, :ask_user, nil)}
  end

  def handle_event("toggle_sidebar", _, socket),
    do: {:noreply, update(socket, :sidebar_open?, &(!&1))}

  def handle_event("toggle_memory", _, socket),
    do: {:noreply, update(socket, :memory_open?, &(!&1))}

  # ── Loop events via PubSub ───────────────────────────────────────────────

  @impl true
  def handle_info(:loop_started, socket), do: {:noreply, assign(socket, :loop_running?, true)}

  def handle_info(:loop_ended, socket) do
    {:noreply,
     socket
     |> assign(:loop_running?, false)
     |> assign(:streaming, nil)
     |> assign(:messages, load_messages(socket.assigns.session_id))
     |> assign(:checkpoint, load_checkpoint(socket.assigns.session_id))
     |> assign(:global_memory, load_global_memory())}
  end

  def handle_info({:message_persisted, _}, socket) do
    {:noreply, assign(socket, :messages, load_messages(socket.assigns.session_id))}
  end

  def handle_info({:turn_start, _n}, socket) do
    {:noreply, assign(socket, :streaming, %{text: "", thinking: "", tool_runs: []})}
  end

  def handle_info({:llm_chunk, t}, socket) do
    s = socket.assigns.streaming || %{text: "", thinking: "", tool_runs: []}
    {:noreply, assign(socket, :streaming, %{s | text: s.text <> t})}
  end

  def handle_info({:llm_thinking, t}, socket) do
    s = socket.assigns.streaming || %{text: "", thinking: "", tool_runs: []}
    {:noreply, assign(socket, :streaming, %{s | thinking: s.thinking <> t})}
  end

  # The text is now persisted; keep tool_runs in-flight, clear text to avoid
  # double-rendering it (assistant message now appears in @messages).
  def handle_info({:llm_done, _resp}, socket) do
    case socket.assigns.streaming do
      nil -> {:noreply, socket}
      s -> {:noreply, assign(socket, :streaming, %{s | text: "", thinking: ""})}
    end
  end

  def handle_info({:tool_start, %{id: id, name: name, args: args}}, socket) do
    s = socket.assigns.streaming || %{text: "", thinking: "", tool_runs: []}
    run = %{id: id, name: name, args: args, output: "", status: :running, data: nil}
    {:noreply, assign(socket, :streaming, %{s | tool_runs: s.tool_runs ++ [run]})}
  end

  def handle_info({:tool_output, t}, socket) do
    case socket.assigns.streaming do
      nil ->
        {:noreply, socket}

      s ->
        new_runs =
          case Enum.reverse(s.tool_runs) do
            [last | rest] -> Enum.reverse([%{last | output: last.output <> t} | rest])
            [] -> []
          end

        {:noreply, assign(socket, :streaming, %{s | tool_runs: new_runs})}
    end
  end

  def handle_info({:tool_done, %{id: id, data: data}}, socket) do
    case socket.assigns.streaming do
      nil ->
        {:noreply, socket}

      s ->
        runs =
          Enum.map(s.tool_runs, fn
            %{id: ^id} = r -> %{r | status: :done, data: data}
            r -> r
          end)

        {:noreply, assign(socket, :streaming, %{s | tool_runs: runs})}
    end
  end

  def handle_info({:ask_user, payload}, socket),
    do: {:noreply, assign(socket, :ask_user, payload)}

  def handle_info({:done, _reason}, socket), do: {:noreply, socket}

  def handle_info({:loop_error, _msg}, socket),
    do: {:noreply, assign(socket, :loop_running?, false)}

  def handle_info(_, socket), do: {:noreply, socket}

  # ── Data loaders ─────────────────────────────────────────────────────────

  defp ensure_session(%{"session_id" => "new"}), do: create_new_session()
  defp ensure_session(%{"session_id" => id}) when is_binary(id), do: {:ok, id}

  defp ensure_session(_) do
    case list_sessions() do
      [%{id: id} | _] -> {:ok, id}
      [] -> create_new_session()
    end
  end

  defp create_new_session do
    {:ok, sess} = Agent.start_session(%{title: "untitled"})
    {:ok, sess.id}
  end

  defp load_session(id) do
    case Agent.get_session(id) do
      {:ok, s} -> s
      _ -> nil
    end
  end

  # Sort by `inserted_at` only: `turn` is reset to 0 at the start of every
  # `Loop.run/1`, so message #1 of the second user prompt has the same
  # `turn` value as message #1 of the first prompt — sorting by turn ends
  # up shuffling the conversation order on multi-prompt sessions.
  defp load_messages(session_id) do
    case Agent.list_messages() do
      {:ok, all} ->
        all
        |> Enum.filter(&(&1.session_id == session_id))
        |> Enum.sort_by(& &1.inserted_at, DateTime)

      _ ->
        []
    end
  end

  defp load_checkpoint(session_id) do
    case Agent.get_checkpoint(session_id) do
      {:ok, cp} -> cp
      _ -> nil
    end
  end

  defp load_global_memory do
    case Agent.list_global_memory() do
      {:ok, rows} -> Enum.sort_by(rows, &{&1.scope, &1.key})
      _ -> []
    end
  end

  defp list_llms do
    case Agent.list_llms() do
      {:ok, rows} -> Enum.filter(rows, & &1.enabled)
      _ -> []
    end
  end

  defp list_sessions do
    case Agent.list_sessions() do
      {:ok, rows} -> Enum.sort_by(rows, & &1.inserted_at, {:desc, DateTime})
      _ -> []
    end
  end

  # Walk the message log into the list the UI should actually render:
  #
  # 1. Drop synthetic user messages (the loop's tool_result hand-off back
  #    to the LLM — content is empty, tool_results is non-empty).
  # 2. Merge consecutive assistant messages from the same loop run into a
  #    single bubble — one Loop.run/1 can emit several `:assistant` rows
  #    (a tool-only turn, then a text turn, etc.) that visually belong
  #    together. Walking them as separate bubbles makes the conversation
  #    look like the AI is talking to itself.
  defp visible_messages(messages) do
    messages
    |> Enum.reject(&synthetic_user?/1)
    |> merge_consecutive_assistants()
  end

  defp synthetic_user?(m) do
    m.role == :user and trimmed_empty?(m.content) and (m.tool_results || []) != []
  end

  defp trimmed_empty?(nil), do: true
  defp trimmed_empty?(c) when is_binary(c), do: String.trim(c) == ""
  defp trimmed_empty?(_), do: false

  defp merge_consecutive_assistants(messages) do
    messages
    |> Enum.chunk_by(& &1.role)
    |> Enum.flat_map(fn
      [single] -> [single]
      [%{role: :assistant} | _] = run -> [merge_assistant_run(run)]
      group -> group
    end)
  end

  defp merge_assistant_run([only]), do: only

  defp merge_assistant_run(msgs) do
    first = hd(msgs)

    %{
      first
      | content: msgs |> Enum.map_join("\n", &(&1.content || "")) |> String.trim(),
        tool_calls: Enum.flat_map(msgs, &(&1.tool_calls || []))
    }
  end

  # ── Markdown-lite ────────────────────────────────────────────────────────
  # Just code fences + inline code; everything else stays as plain text
  # honoring `whitespace-pre-wrap`. Avoids hauling in earmark for now.
  defp format_text(nil), do: ""
  defp format_text(""), do: ""

  defp format_text(text) when is_binary(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> apply_code_fences()
    |> apply_inline_code()
    |> Phoenix.HTML.raw()
  end

  defp apply_code_fences(html) do
    Regex.replace(~r/```([a-zA-Z0-9_]*)\n?([\s\S]*?)```/, html, fn _full, _lang, code ->
      ~s|<pre class="bg-zinc-900 text-zinc-100 rounded-md p-3 my-2 overflow-x-auto text-xs leading-snug font-mono"><code>#{code}</code></pre>|
    end)
  end

  defp apply_inline_code(html) do
    Regex.replace(~r/`([^`\n]+)`/, html, fn _full, code ->
      ~s|<code class="bg-zinc-200/70 text-zinc-800 px-1.5 py-0.5 rounded text-[0.85em] font-mono">#{code}</code>|
    end)
  end

  defp short_args(args) when is_map(args) do
    args |> Long.Util.Utf8.sanitize() |> Jason.encode!() |> truncate(80)
  end

  defp short_args(_), do: ""

  defp truncate(s, max) when byte_size(s) > max, do: binary_part(s, 0, max) <> "…"
  defp truncate(s, _), do: s

  defp tool_status_pill(:running),
    do: {"bg-amber-100 text-amber-800 ring-amber-200", "running…", "animate-pulse"}

  defp tool_status_pill(:done),
    do: {"bg-emerald-100 text-emerald-800 ring-emerald-200", "✓ done", ""}

  defp tool_status_pill(_), do: {"bg-zinc-100 text-zinc-700 ring-zinc-200", "?", ""}

  defp format_data(nil), do: nil
  defp format_data(d) when is_binary(d), do: d
  defp format_data(d), do: d |> Long.Util.Utf8.sanitize() |> Jason.encode!(pretty: true)

  # ── Template ─────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-zinc-100 text-zinc-900">
      <.sessions_pane sessions={@sessions} session_id={@session_id} open?={@sidebar_open?} />

      <main class="flex-1 flex flex-col min-w-0">
        <.chat_header
          session={@session}
          available_llms={@available_llms}
          sidebar_open?={@sidebar_open?}
          memory_open?={@memory_open?}
        />

        <div
          id="thread"
          phx-hook=".ScrollBottom"
          class="flex-1 overflow-y-auto px-4 sm:px-8 py-6 space-y-4"
        >
          <.empty_state :if={visible_messages(@messages) == [] and is_nil(@streaming)} />

          <.message_bubble :for={msg <- visible_messages(@messages)} msg={msg} />

          <.streaming_bubble :if={@streaming != nil} streaming={@streaming} />

          <.ask_user_card :if={@ask_user} ask={@ask_user} />
        </div>

        <.composer loop_running?={@loop_running?} />

        <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollBottom">
          export default {
            mounted() { this.scrollToBottom(); this.observe(); },
            updated() { if (this.atBottom) this.scrollToBottom(); },
            observe() {
              this.atBottom = true;
              this.el.addEventListener("scroll", () => {
                const slack = 32;
                this.atBottom =
                  this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < slack;
              });
            },
            scrollToBottom() { this.el.scrollTop = this.el.scrollHeight; },
          };
        </script>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".Composer">
          export default {
            mounted() {
              const ta = this.el.querySelector("textarea");
              const form = this.el;
              ta.addEventListener("keydown", (e) => {
                if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
                  e.preventDefault();
                  form.requestSubmit();
                }
              });
              ta.addEventListener("input", () => this.autosize(ta));
              this.autosize(ta);
              this.handleEvent("agent:clear-composer", () => {
                ta.value = "";
                this.autosize(ta);
                ta.focus();
              });
            },
            autosize(ta) {
              ta.style.height = "auto";
              ta.style.height = Math.min(ta.scrollHeight, 240) + "px";
            },
          };
        </script>
      </main>

      <.memory_pane checkpoint={@checkpoint} global_memory={@global_memory} open?={@memory_open?} />
    </div>
    """
  end

  # ── Components ───────────────────────────────────────────────────────────

  attr :sessions, :list, required: true
  attr :session_id, :string, required: true
  attr :open?, :boolean, required: true

  defp sessions_pane(assigns) do
    ~H"""
    <aside class={[
      "border-r border-zinc-200 bg-white flex flex-col transition-all overflow-hidden",
      @open? && "w-60",
      !@open? && "w-0"
    ]}>
      <div class="p-3 border-b border-zinc-200">
        <button
          phx-click="new_session"
          class="w-full px-3 py-2 rounded-lg bg-zinc-900 text-white text-sm font-medium hover:bg-zinc-700 transition"
        >
          + New session
        </button>
      </div>
      <ul class="flex-1 overflow-y-auto text-sm">
        <li
          :for={s <- @sessions}
          phx-click="switch_session"
          phx-value-id={s.id}
          class={[
            "px-3 py-2.5 border-b border-zinc-100 cursor-pointer hover:bg-zinc-50 transition",
            s.id == @session_id && "bg-blue-50 border-l-2 border-l-blue-500"
          ]}
        >
          <div class="truncate font-medium text-zinc-800">{s.title}</div>
          <div class="text-xs text-zinc-400 mt-0.5">
            {s.status} · {Calendar.strftime(s.inserted_at, "%m-%d %H:%M")}
          </div>
        </li>
      </ul>
    </aside>
    """
  end

  attr :session, :any, required: true
  attr :available_llms, :list, required: true
  attr :sidebar_open?, :boolean, required: true
  attr :memory_open?, :boolean, required: true

  defp chat_header(assigns) do
    ~H"""
    <header class="bg-white border-b border-zinc-200 px-4 sm:px-6 h-14 flex items-center gap-3 shrink-0">
      <button
        phx-click="toggle_sidebar"
        class="p-1.5 rounded hover:bg-zinc-100 text-zinc-500"
        title={if @sidebar_open?, do: "Hide sessions", else: "Show sessions"}
      >
        ☰
      </button>
      <div class="font-semibold truncate">{(@session && @session.title) || "—"}</div>
      <div class="flex-1" />
      <form phx-change="set_llm" class="flex items-center gap-2 text-xs text-zinc-500">
        <span>Model</span>
        <select name="alias" class="border border-zinc-300 rounded px-2 py-1 text-xs bg-white">
          <option value="" selected={is_nil(@session && @session.llm_alias)}>
            echo (demo)
          </option>
          <option
            :for={llm <- @available_llms}
            value={llm.alias}
            selected={@session && @session.llm_alias == llm.alias}
          >
            {llm.alias}
          </option>
        </select>
      </form>
      <button
        phx-click="toggle_memory"
        class="p-1.5 rounded hover:bg-zinc-100 text-zinc-500"
        title={if @memory_open?, do: "Hide memory", else: "Show memory"}
      >
        ☷
      </button>
    </header>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="h-full flex flex-col items-center justify-center text-center text-zinc-400 py-20">
      <div class="text-5xl mb-4">💬</div>
      <div class="text-zinc-500 font-medium">Start a conversation</div>
      <div class="text-xs mt-1.5 max-w-xs">
        Type a message below. The agent has access to file I/O, code execution,
        memory, HTTP fetch, and browser tools.
      </div>
    </div>
    """
  end

  attr :msg, :any, required: true

  defp message_bubble(%{msg: %{role: :user}} = assigns) do
    ~H"""
    <article class="flex justify-end">
      <div class="max-w-[75%] bg-blue-600 text-white px-4 py-2.5 rounded-2xl rounded-tr-md">
        <div class="whitespace-pre-wrap break-words">{@msg.content}</div>
      </div>
    </article>
    """
  end

  defp message_bubble(%{msg: %{role: :assistant}} = assigns) do
    ~H"""
    <article class="flex justify-start">
      <div class="max-w-[85%] bg-white border border-zinc-200 px-4 py-3 rounded-2xl rounded-tl-md shadow-sm">
        <div
          :if={(@msg.content || "") != ""}
          class="whitespace-pre-wrap break-words leading-relaxed"
        >
          {format_text(@msg.content)}
        </div>
        <.tool_call_list :if={(@msg.tool_calls || []) != []} tool_calls={@msg.tool_calls} />
      </div>
    </article>
    """
  end

  defp message_bubble(assigns), do: ~H""

  attr :tool_calls, :list, required: true

  defp tool_call_list(assigns) do
    ~H"""
    <div class="mt-3 space-y-1.5">
      <details :for={tc <- @tool_calls} class="group">
        <summary class="cursor-pointer text-xs text-zinc-600 hover:text-zinc-900 select-none">
          <span class="font-mono">🛠 {tc["name"]}</span>
          <span class="text-zinc-400">({short_args(tc["input"] || %{})})</span>
        </summary>
        <pre class="mt-1.5 text-[11px] bg-zinc-50 border border-zinc-200 rounded p-2 overflow-x-auto leading-snug font-mono">{format_data(tc["input"] || %{})}</pre>
      </details>
    </div>
    """
  end

  attr :streaming, :map, required: true

  defp streaming_bubble(assigns) do
    ~H"""
    <article class="flex justify-start">
      <div class="max-w-[85%] bg-white border border-zinc-200 px-4 py-3 rounded-2xl rounded-tl-md shadow-sm">
        <details :if={@streaming.thinking != ""} class="mb-2">
          <summary class="cursor-pointer text-xs text-zinc-400">thinking…</summary>
          <pre class="mt-1.5 text-xs text-zinc-500 whitespace-pre-wrap leading-snug">{@streaming.thinking}</pre>
        </details>
        <div :if={@streaming.text != ""} class="whitespace-pre-wrap break-words leading-relaxed">
          {format_text(@streaming.text)}<span class="inline-block w-2 h-4 ml-0.5 align-middle bg-zinc-400 animate-pulse rounded-sm" />
        </div>
        <div
          :if={@streaming.text == "" and @streaming.tool_runs == []}
          class="flex items-center gap-2 text-sm text-zinc-400"
        >
          <span class="flex gap-1">
            <span class="w-1.5 h-1.5 rounded-full bg-zinc-300 animate-bounce [animation-delay:0ms]" />
            <span class="w-1.5 h-1.5 rounded-full bg-zinc-300 animate-bounce [animation-delay:150ms]" />
            <span class="w-1.5 h-1.5 rounded-full bg-zinc-300 animate-bounce [animation-delay:300ms]" />
          </span>
          thinking
        </div>
        <.tool_run_card :for={run <- @streaming.tool_runs} run={run} />
      </div>
    </article>
    """
  end

  attr :run, :map, required: true

  defp tool_run_card(assigns) do
    {pill_class, pill_label, pulse} = tool_status_pill(assigns.run.status)

    assigns =
      assign(assigns, :pill_class, pill_class)
      |> assign(:pill_label, pill_label)
      |> assign(:pulse, pulse)

    ~H"""
    <div class="mt-3 border border-zinc-200 rounded-lg bg-zinc-50/50 overflow-hidden">
      <div class="px-3 py-2 flex items-center justify-between text-xs">
        <span class="font-mono text-zinc-700">🛠 {@run.name}</span>
        <span class={["ring-1 rounded-full px-2 py-0.5 text-[10px] font-medium", @pill_class, @pulse]}>
          {@pill_label}
        </span>
      </div>
      <details class="px-3 pb-2 text-[11px] text-zinc-500">
        <summary class="cursor-pointer">args</summary>
        <pre class="mt-1 bg-white border border-zinc-200 rounded p-2 overflow-x-auto leading-snug font-mono text-zinc-700">{format_data(@run.args || %{})}</pre>
      </details>
      <pre
        :if={@run.output != ""}
        class="mx-3 mb-2 text-[11px] bg-zinc-900 text-zinc-100 rounded p-2 overflow-x-auto whitespace-pre-wrap break-words leading-snug font-mono"
      >{@run.output}</pre>
      <details :if={@run.data != nil} class="px-3 pb-2 text-[11px] text-zinc-500">
        <summary class="cursor-pointer">result</summary>
        <pre class="mt-1 bg-white border border-zinc-200 rounded p-2 overflow-x-auto leading-snug font-mono text-zinc-700">{format_data(@run.data)}</pre>
      </details>
    </div>
    """
  end

  attr :ask, :map, required: true

  defp ask_user_card(assigns) do
    ~H"""
    <article class="border-2 border-amber-400 rounded-2xl p-4 bg-amber-50 max-w-2xl mx-auto shadow">
      <div class="font-semibold text-amber-900 mb-2">The agent is asking:</div>
      <p class="mb-3 text-amber-950">{@ask["question"]}</p>
      <form phx-submit="answer_ask_user" class="flex gap-2">
        <input
          name="answer"
          autofocus
          class="flex-1 border border-amber-300 rounded-lg px-3 py-2 bg-white focus:ring-2 focus:ring-amber-400 outline-none"
          placeholder="Type your answer…"
        />
        <button
          type="submit"
          class="px-4 py-2 bg-amber-600 hover:bg-amber-700 text-white rounded-lg font-medium"
        >
          Send
        </button>
      </form>
      <div :if={(@ask["candidates"] || []) != []} class="mt-3 flex gap-2 flex-wrap">
        <button
          :for={c <- @ask["candidates"]}
          phx-click="answer_ask_user"
          phx-value-answer={c}
          class="text-xs px-3 py-1.5 bg-white border border-amber-200 rounded-full hover:bg-amber-100 text-amber-900"
        >
          {c}
        </button>
      </div>
    </article>
    """
  end

  attr :loop_running?, :boolean, required: true

  defp composer(assigns) do
    ~H"""
    <form
      id="composer"
      phx-submit="submit"
      phx-hook=".Composer"
      class="border-t border-zinc-200 bg-white px-4 sm:px-6 py-3"
    >
      <div class="flex items-end gap-3 max-w-4xl mx-auto">
        <textarea
          name="input"
          rows="1"
          placeholder={
            if @loop_running?,
              do: "Working…",
              else: "Send a message  (Enter to send · Shift+Enter for newline)"
          }
          class="flex-1 resize-none border border-zinc-300 rounded-2xl px-4 py-2.5 leading-relaxed bg-white focus:ring-2 focus:ring-blue-500 focus:border-transparent outline-none max-h-60"
          autofocus
        ></textarea>
        <button
          type="submit"
          disabled={@loop_running?}
          class={[
            "shrink-0 h-10 w-10 rounded-full flex items-center justify-center text-white transition shadow",
            !@loop_running? && "bg-blue-600 hover:bg-blue-700",
            @loop_running? && "bg-zinc-400 cursor-not-allowed"
          ]}
          title="Send"
        >
          <span class={if @loop_running?, do: "animate-spin text-sm", else: "text-base"}>
            {if @loop_running?, do: "◌", else: "↑"}
          </span>
        </button>
      </div>
    </form>
    """
  end

  attr :checkpoint, :any, required: true
  attr :global_memory, :list, required: true
  attr :open?, :boolean, required: true

  defp memory_pane(assigns) do
    ~H"""
    <aside class={[
      "border-l border-zinc-200 bg-white overflow-y-auto transition-all",
      @open? && "w-72",
      !@open? && "w-0"
    ]}>
      <div class="p-4">
        <h3 class="text-[11px] uppercase tracking-wide font-semibold text-zinc-500 mb-2">
          L1 · Working memory
        </h3>
        <pre class="text-xs bg-zinc-50 border border-zinc-200 p-2.5 rounded whitespace-pre-wrap text-zinc-700 leading-snug min-h-[1.5em]">{(@checkpoint && @checkpoint.key_info) || "(empty)"}</pre>

        <h3 class="text-[11px] uppercase tracking-wide font-semibold text-zinc-500 mt-5 mb-2">
          L2 · Global memory
        </h3>
        <p :if={@global_memory == []} class="text-xs text-zinc-400">(empty)</p>
        <ul :if={@global_memory != []} class="space-y-2 text-xs">
          <li :for={entry <- @global_memory} class="border-l-2 border-zinc-200 pl-2.5">
            <div class="text-[10px] uppercase tracking-wide text-zinc-400">{entry.scope}</div>
            <div class="font-medium text-zinc-700">{entry.key}</div>
            <div class="text-zinc-500 leading-snug">{entry.value}</div>
          </li>
        </ul>
      </div>
    </aside>
    """
  end
end
