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

    if connected?(socket) do
      SessionRunner.subscribe(session_id)
      Long.Agent.SessionPubSub.subscribe()
    end

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
     |> assign(:loop_notice, nil)
     |> assign(:sessions, list_sessions())
     |> assign(:sidebar_open?, true)
     |> assign(:memory_open?, true)
     |> assign(:editing_title?, false)}
  end

  @impl true
  def handle_event("dismiss_notice", _, socket), do: {:noreply, assign(socket, :loop_notice, nil)}

  def handle_event("submit", %{"input" => text}, socket) do
    case String.trim(text) do
      "" ->
        {:noreply, socket}

      "/clear" ->
        Long.Agent.SessionClear.clear(socket.assigns.session_id)

        {:noreply,
         socket
         |> assign(:messages, load_messages(socket.assigns.session_id))
         |> assign(:checkpoint, load_checkpoint(socket.assigns.session_id))
         |> assign(:streaming, nil)
         |> assign(:loop_running?, false)
         |> assign(:loop_notice, %{kind: :info, text: "已清空这条会话的历史、摘要、检查点和 session 记忆。"})
         |> push_event("agent:clear-composer", %{})}

      trimmed ->
        SessionRunner.send_user_message(socket.assigns.session_id, trimmed)

        {:noreply,
         socket
         |> assign(:loop_running?, true)
         |> assign(:loop_notice, nil)
         |> assign(:streaming, %{text: "", thinking: "", tool_runs: []})
         |> push_event("agent:clear-composer", %{})}
    end
  end

  def handle_event("new_session", _, socket) do
    {:ok, sess} =
      Agent.start_session(%{title: "untitled", llm_alias: Agent.default_llm_alias()})

    {:noreply, push_navigate(socket, to: ~p"/chat/#{sess.id}")}
  end

  def handle_event("switch_session", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/chat/#{id}")}
  end

  def handle_event("destroy_session", %{"id" => id}, socket) do
    with {:ok, sess} <- Agent.get_session(id),
         :ok <- Agent.destroy_session(sess) do
      target =
        case list_sessions() do
          [%{id: next_id} | _] -> ~p"/chat/#{next_id}"
          [] -> ~p"/chat"
        end

      {:noreply, push_navigate(socket, to: target)}
    else
      _ -> {:noreply, socket}
    end
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

  def handle_event("edit_title", _, socket),
    do: {:noreply, assign(socket, :editing_title?, true)}

  def handle_event("cancel_title", _, socket),
    do: {:noreply, assign(socket, :editing_title?, false)}

  def handle_event("save_title", %{"title" => title}, socket) do
    case String.trim(title) do
      "" ->
        {:noreply, assign(socket, :editing_title?, false)}

      cleaned ->
        # `title_locked: true` keeps TitleGen from overwriting this on
        # the next loop_ended — manual edits win against auto-gen.
        {:ok, sess} =
          Agent.update_session(socket.assigns.session, %{
            title: cleaned,
            title_locked: true
          })

        {:noreply,
         socket
         |> assign(:session, sess)
         |> assign(:editing_title?, false)
         |> assign(:sessions, list_sessions())}
    end
  end

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

  # /clear was issued (here or from a bot platform); messages + summary
  # + checkpoint were wiped. Reload them so a stale UI doesn't keep
  # showing the conversation that no longer exists in the DB.
  def handle_info(:session_cleared, socket) do
    {:noreply,
     socket
     |> assign(:messages, load_messages(socket.assigns.session_id))
     |> assign(:checkpoint, load_checkpoint(socket.assigns.session_id))
     |> assign(:streaming, nil)
     |> assign(:loop_running?, false)}
  end

  def handle_info({:session_updated, session}, socket) do
    socket =
      if session.id == socket.assigns.session_id do
        assign(socket, :session, session)
      else
        socket
      end

    {:noreply, assign(socket, :sessions, list_sessions())}
  end

  def handle_info({:session_created, _session}, socket) do
    {:noreply, assign(socket, :sessions, list_sessions())}
  end

  def handle_info({:session_destroyed, id}, socket) do
    sessions = list_sessions()

    cond do
      # The session we're currently viewing got destroyed — navigate
      # to the next available one, or back to the index.
      id == socket.assigns.session_id ->
        target =
          case sessions do
            [%{id: next} | _] -> ~p"/chat/#{next}"
            [] -> ~p"/chat"
          end

        {:noreply, push_navigate(socket, to: target)}

      true ->
        {:noreply, assign(socket, :sessions, sessions)}
    end
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

  def handle_info({:done, reason}, socket) do
    {:noreply, assign(socket, :loop_notice, SessionRunner.done_notice(reason))}
  end

  def handle_info({:loop_error, msg}, socket) do
    {:noreply,
     socket
     |> assign(:loop_running?, false)
     |> assign(:loop_notice, %{kind: :error, text: "Agent error: " <> to_string(msg)})}
  end

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
    {:ok, sess} =
      Agent.start_session(%{title: "untitled", llm_alias: Agent.default_llm_alias()})

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
    args |> Long.Util.Utf8.sanitize() |> Jason.encode!() |> Long.Util.Text.preview(80)
  end

  defp short_args(_), do: ""

  # Maps tool status to a `<.badge>` color + label. `pulse?` is a class
  # we toggle on the badge to indicate work-in-progress without inventing
  # a new variant.
  defp tool_status_badge(:running), do: {"warning", "running…", true}
  defp tool_status_badge(:done), do: {"success", "✓ done", false}
  defp tool_status_badge(_), do: {"silver", "?", false}

  defp notice_alert_kind(:warning), do: :warning
  defp notice_alert_kind(:error), do: :danger
  defp notice_alert_kind(_), do: :natural

  defp llm_label(%{alias: a, default: true}), do: "★ " <> a
  defp llm_label(%{alias: a}), do: a

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
          editing_title?={@editing_title?}
        />

        <div
          id="thread"
          phx-hook=".ScrollBottom"
          class="flex-1 overflow-y-auto px-4 sm:px-8 pt-6 pb-8 space-y-4"
        >
          <.empty_state :if={visible_messages(@messages) == [] and is_nil(@streaming)} />
          <.message_bubble :for={msg <- visible_messages(@messages)} msg={msg} />
          <.streaming_bubble :if={@streaming != nil} streaming={@streaming} />
          <.ask_user_card :if={@ask_user} ask={@ask_user} />
          <.loop_notice :if={@loop_notice} notice={@loop_notice} />
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
      "h-full border-r border-zinc-200 bg-white flex flex-col transition-all overflow-hidden shrink-0",
      @open? && "w-60",
      !@open? && "w-0"
    ]}>
      <div class="p-3 border-b border-zinc-200">
        <.button
          phx-click="new_session"
          color="primary"
          full_width
          icon="hero-plus"
          rounded="large"
          size="medium"
        >
          New session
        </.button>
      </div>
      <ul class="flex-1 overflow-y-auto text-sm">
        <li
          :for={s <- @sessions}
          class={[
            "group border-b border-zinc-100 flex items-center transition",
            s.id == @session_id && "bg-blue-50 border-l-2 border-l-blue-500"
          ]}
        >
          <button
            type="button"
            phx-click="switch_session"
            phx-value-id={s.id}
            class="flex-1 min-w-0 text-left px-3 py-2.5 cursor-pointer hover:bg-zinc-50 transition"
          >
            <div class="truncate font-medium text-zinc-800">{s.title}</div>
            <div class="text-xs text-zinc-400 mt-0.5">
              {s.status} · {Calendar.strftime(s.inserted_at, "%m-%d %H:%M")}
            </div>
          </button>
          <button
            type="button"
            phx-click="destroy_session"
            phx-value-id={s.id}
            data-confirm={"Delete \"#{s.title}\" and all its messages?"}
            class="px-2 py-2 mr-1 text-zinc-400 hover:text-red-600 hover:bg-red-50 rounded opacity-0 group-hover:opacity-100 transition"
            title="Delete session"
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </li>
      </ul>
      <div class="p-2 border-t border-zinc-200">
        <.button_link
          navigate={~p"/manage"}
          variant="base"
          color="natural"
          full_width
          size="small"
          icon="hero-cog-6-tooth"
          rounded="medium"
        >
          Manage
        </.button_link>
      </div>
    </aside>
    """
  end

  attr :session, :any, required: true
  attr :available_llms, :list, required: true
  attr :sidebar_open?, :boolean, required: true
  attr :memory_open?, :boolean, required: true
  attr :editing_title?, :boolean, required: true

  defp chat_header(assigns) do
    ~H"""
    <header class="bg-white border-b border-zinc-200 px-4 sm:px-6 h-14 flex items-center gap-3 shrink-0">
      <.button
        phx-click="toggle_sidebar"
        variant="base"
        color="natural"
        rounded="small"
        size="extra_small"
        icon="hero-bars-3"
        class="!p-2"
        title={if @sidebar_open?, do: "Hide sessions", else: "Show sessions"}
      />
      <.session_title session={@session} editing?={@editing_title?} />
      <div class="flex-1" />
      <form phx-change="set_llm" class="flex items-center gap-2 text-xs text-zinc-500">
        <span>Model</span>
        <.native_select name="alias" size="extra_small" space="none">
          <:option value="" selected={is_nil(@session && @session.llm_alias)}>echo (demo)</:option>
          <:option
            :for={llm <- @available_llms}
            value={llm.alias}
            selected={@session && @session.llm_alias == llm.alias}
          >
            {llm_label(llm)}
          </:option>
        </.native_select>
      </form>
      <.button
        phx-click="toggle_memory"
        variant="base"
        color="natural"
        rounded="small"
        size="extra_small"
        icon="hero-bars-4"
        class="!p-2"
        title={if @memory_open?, do: "Hide memory", else: "Show memory"}
      />
    </header>
    """
  end

  attr :session, :any, required: true
  attr :editing?, :boolean, required: true

  defp session_title(%{editing?: true} = assigns) do
    ~H"""
    <form phx-submit="save_title" class="flex items-center gap-1 min-w-0">
      <input
        type="text"
        name="title"
        value={@session && @session.title}
        autofocus
        phx-key="escape"
        phx-keyup="cancel_title"
        class="font-semibold border border-zinc-300 rounded px-2 py-0.5 text-sm bg-white focus:ring-2 focus:ring-blue-400 outline-none min-w-0 max-w-xs"
      />
      <.button type="submit" color="primary" size="extra_small" rounded="medium" icon="hero-check" class="!p-1.5" title="Save (Enter)" />
      <.button
        type="button"
        phx-click="cancel_title"
        variant="base"
        color="natural"
        size="extra_small"
        rounded="medium"
        icon="hero-x-mark"
        class="!p-1.5"
        title="Cancel (Esc)"
      />
    </form>
    """
  end

  defp session_title(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="edit_title"
      class="font-semibold truncate hover:bg-zinc-100 px-2 py-0.5 rounded transition text-left max-w-md"
      title="Click to rename"
    >
      {(@session && @session.title) || "—"}
    </button>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="h-full flex flex-col items-center justify-center text-center text-zinc-400 py-20">
      <.icon name="hero-chat-bubble-left-right" class="size-14 mb-4 text-zinc-300" />
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
    <.chat
      position="flipped"
      color="info"
      variant="default"
      rounded="extra_large"
      padding="none"
      class="[&>.chat-section-bubble]:!max-w-[75%]"
    >
      <.chat_section class="px-4 py-2.5 text-[15px] leading-relaxed">
        <div class="whitespace-pre-wrap break-words">{@msg.content}</div>
      </.chat_section>
    </.chat>
    """
  end

  defp message_bubble(%{msg: %{role: :assistant}} = assigns) do
    ~H"""
    <.chat
      position="normal"
      color="natural"
      variant="bordered"
      rounded="extra_large"
      padding="none"
      class="[&>.chat-section-bubble]:!max-w-[85%] [&>.chat-section-bubble]:bg-white [&>.chat-section-bubble]:border-zinc-300 [&>.chat-section-bubble]:shadow-sm"
    >
      <.chat_section class="px-4 py-3 text-[15px] leading-relaxed">
        <div :if={(@msg.content || "") != ""} class="whitespace-pre-wrap break-words">
          {format_text(@msg.content)}
        </div>
        <.tool_call_list :if={(@msg.tool_calls || []) != []} tool_calls={@msg.tool_calls} />
      </.chat_section>
    </.chat>
    """
  end

  defp message_bubble(assigns), do: ~H""

  attr :tool_calls, :list, required: true

  defp tool_call_list(assigns) do
    ~H"""
    <div class="mt-3 space-y-1.5">
      <details :for={tc <- @tool_calls} class="group">
        <summary class="cursor-pointer text-xs text-zinc-600 hover:text-zinc-900 select-none flex items-center gap-2">
          <.badge color="misc" size="extra_small" icon="hero-wrench-screwdriver" rounded="full">
            {tc["name"]}
          </.badge>
          <span class="text-zinc-400 font-mono">({short_args(tc["input"] || %{})})</span>
        </summary>
        <pre class="mt-1.5 text-[11px] bg-zinc-50 border border-zinc-200 rounded p-2 overflow-x-auto leading-snug font-mono">{format_data(tc["input"] || %{})}</pre>
      </details>
    </div>
    """
  end

  attr :streaming, :map, required: true

  defp streaming_bubble(assigns) do
    ~H"""
    <.chat
      position="normal"
      color="natural"
      variant="bordered"
      rounded="extra_large"
      padding="none"
      class="[&>.chat-section-bubble]:!max-w-[85%] [&>.chat-section-bubble]:bg-white [&>.chat-section-bubble]:border-zinc-300 [&>.chat-section-bubble]:shadow-sm"
    >
      <.chat_section class="px-4 py-3 text-[15px] leading-relaxed">
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
          <.spinner color="natural" size="extra_small" /> thinking
        </div>
        <.tool_run_card :for={run <- @streaming.tool_runs} run={run} />
      </.chat_section>
    </.chat>
    """
  end

  attr :run, :map, required: true

  defp tool_run_card(assigns) do
    {badge_color, badge_label, pulse?} = tool_status_badge(assigns.run.status)

    assigns =
      assigns
      |> assign(:badge_color, badge_color)
      |> assign(:badge_label, badge_label)
      |> assign(:pulse?, pulse?)

    ~H"""
    <.card variant="bordered" color="silver" rounded="large" padding="none" class="mt-3">
      <div class="px-3 py-2 flex items-center justify-between text-xs">
        <.badge color="misc" size="extra_small" icon="hero-wrench-screwdriver" rounded="full">
          {@run.name}
        </.badge>
        <.badge
          color={@badge_color}
          size="extra_small"
          rounded="full"
          class={@pulse? && "animate-pulse"}
        >
          {@badge_label}
        </.badge>
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
    </.card>
    """
  end

  attr :notice, :map, required: true

  defp loop_notice(assigns) do
    assigns = assign(assigns, :alert_kind, notice_alert_kind(assigns.notice.kind))

    ~H"""
    <.alert kind={@alert_kind} rounded="extra_large" class="max-w-2xl mx-auto">
      <div class="flex items-start gap-3">
        <div class="flex-1">{@notice.text}</div>
        <button
          type="button"
          phx-click="dismiss_notice"
          class="text-xs underline opacity-70 hover:opacity-100"
        >
          dismiss
        </button>
      </div>
    </.alert>
    """
  end

  attr :ask, :map, required: true

  defp ask_user_card(assigns) do
    ~H"""
    <.alert
      kind={:warning}
      title="The agent is asking"
      rounded="extra_large"
      class="max-w-2xl mx-auto"
    >
      <p class="mb-3">{@ask["question"]}</p>
      <form phx-submit="answer_ask_user" class="flex gap-2 mb-3">
        <input
          name="answer"
          autofocus
          class="flex-1 border border-amber-300 rounded-lg px-3 py-2 bg-white focus:ring-2 focus:ring-amber-400 outline-none"
          placeholder="Type your answer…"
        />
        <.button type="submit" color="warning" rounded="large" size="small">Send</.button>
      </form>
      <div :if={(@ask["candidates"] || []) != []} class="flex gap-2 flex-wrap">
        <.button
          :for={c <- @ask["candidates"]}
          phx-click="answer_ask_user"
          phx-value-answer={c}
          size="extra_small"
          rounded="full"
          variant="outline"
          color="warning"
        >
          {c}
        </.button>
      </div>
    </.alert>
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
          class="flex-1 resize-none border border-zinc-300 rounded-2xl px-4 py-3 leading-relaxed bg-white focus:ring-2 focus:ring-blue-500 focus:border-transparent outline-none max-h-60"
          autofocus
        ></textarea>
        <.button
          type="submit"
          disabled={@loop_running?}
          color={if @loop_running?, do: "natural", else: "primary"}
          rounded="full"
          size="medium"
          icon={if @loop_running?, do: "hero-arrow-path", else: "hero-paper-airplane"}
          icon_class={@loop_running? && "animate-spin"}
          class="!h-[50px] !w-[50px] !p-0 shrink-0 flex items-center justify-center"
          title="Send"
        />
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
      "h-full border-l border-zinc-200 bg-white overflow-y-auto transition-all shrink-0",
      @open? && "w-72",
      !@open? && "w-0"
    ]}>
      <div class="p-4 space-y-4">
        <.card variant="bordered" color="natural" rounded="large" padding="small">
          <.card_title title="L1 · Working memory" size="extra_small" class="text-zinc-500 uppercase" />
          <pre class="text-xs whitespace-pre-wrap text-zinc-700 leading-snug min-h-[1.5em]">{(@checkpoint && @checkpoint.key_info) || "(empty)"}</pre>
        </.card>

        <.card variant="bordered" color="natural" rounded="large" padding="small">
          <.card_title title="L2 · Global memory" size="extra_small" class="text-zinc-500 uppercase" />
          <p :if={@global_memory == []} class="text-xs text-zinc-400">(empty)</p>
          <ul :if={@global_memory != []} class="space-y-2 text-xs">
            <li :for={entry <- @global_memory} class="border-l-2 border-zinc-200 pl-2.5">
              <div class="text-[10px] uppercase tracking-wide text-zinc-400">{entry.scope}</div>
              <div class="font-medium text-zinc-700">{entry.key}</div>
              <div class="text-zinc-500 leading-snug">{entry.value}</div>
            </li>
          </ul>
        </.card>
      </div>
    </aside>
    """
  end
end
