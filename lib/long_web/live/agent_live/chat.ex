defmodule LongWeb.AgentLive.Chat do
  @moduledoc """
  Phase 6 — the LiveView the user interacts with. Subscribes to the
  session's PubSub topic, renders streaming LLM output and tool runs in
  real time, and surfaces the L1/L2 memory in the right rail.
  """

  use LongWeb, :live_view

  # Petal Components are called qualified during the gradual migration off mishka.
  alias PetalComponents.{Badge, Button}

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
     |> assign(:editing_title?, false)
     |> allow_upload(:attachments, accept: :any, max_entries: 6, max_file_size: 25_000_000)}
  end

  @impl true
  def handle_event("dismiss_notice", _, socket), do: {:noreply, assign(socket, :loop_notice, nil)}

  def handle_event("submit", %{"input" => text}, socket) do
    trimmed = String.trim(text)

    cond do
      trimmed == "/clear" ->
        Long.Agent.SessionClear.clear(socket.assigns.session_id)

        {:noreply,
         socket
         |> assign(:messages, load_messages(socket.assigns.session_id))
         |> assign(:checkpoint, load_checkpoint(socket.assigns.session_id))
         |> assign(:streaming, nil)
         |> assign(:loop_running?, false)
         |> assign(:loop_notice, %{kind: :info, text: Long.Copy.t("bots.cleared")})
         |> push_event("agent:clear-composer", %{})}

      trimmed == "" and socket.assigns.uploads.attachments.entries == [] ->
        {:noreply, socket}

      true ->
        attachments = consume_attachments(socket)
        SessionRunner.send_user_message(socket.assigns.session_id, trimmed, attachments: attachments)

        {:noreply,
         socket
         |> assign(:loop_running?, true)
         |> assign(:loop_notice, nil)
         |> assign(:streaming, %{text: "", thinking: "", tool_runs: []})
         |> push_event("agent:clear-composer", %{})}
    end
  end

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :attachments, ref)}

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
  # Clear any ask_user card on resume: the turn restarted because the prompt
  # was answered — here, from a bot channel (web answers clear it directly),
  # or simply superseded by a new message.
  def handle_info(:loop_started, socket),
    do: {:noreply, socket |> assign(:loop_running?, true) |> assign(:ask_user, nil)}

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
    |> Enum.reject(&internal?/1)
    |> Enum.reject(&synthetic_user?/1)
    |> merge_consecutive_assistants()
  end

  # Silent-reflection rows never render in /chat. `Long.Agent.Server`
  # already suppresses their `:message_persisted` broadcast, so they don't
  # even trigger a reload; this is the render-time backstop for the
  # `:loop_ended`/full-reload path.
  defp internal?(%{internal: true}), do: true
  defp internal?(_), do: false

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
  defp tool_status_badge(_), do: {"gray", "?", false}

  defp notice_classes(:warning), do: "border-amber-200 bg-amber-50 text-amber-900"
  defp notice_classes(:error), do: "border-red-200 bg-red-50 text-red-900"
  defp notice_classes(_), do: "border-zinc-200 bg-zinc-50 text-zinc-700"

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

        <.composer loop_running?={@loop_running?} uploads={@uploads} />

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
        <Button.button
          phx-click="new_session"
          color="primary"
          radius="lg"
          icon="hero-plus"
          class="w-full"
        >
          {gettext("New session")}
        </Button.button>
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
            data-confirm={gettext("Delete \"%{title}\" and all its messages?", title: s.title)}
            class="px-2 py-2 mr-1 text-zinc-400 hover:text-red-600 hover:bg-red-50 rounded opacity-0 group-hover:opacity-100 transition"
            title={gettext("Delete session")}
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </li>
      </ul>
      <div class="p-2 border-t border-zinc-200">
        <Button.button
          link_type="live_redirect"
          to={~p"/manage"}
          variant="outline"
          color="gray"
          size="sm"
          icon="hero-cog-6-tooth"
          class="w-full"
        >
          {gettext("Manage")}
        </Button.button>
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
      <Button.icon_button
        phx-click="toggle_sidebar"
        color="gray"
        title={if @sidebar_open?, do: gettext("Hide sessions"), else: gettext("Show sessions")}
      >
        <.icon name="hero-bars-3" class="size-5" />
      </Button.icon_button>
      <.session_title session={@session} editing?={@editing_title?} />
      <div class="flex-1" />
      <form phx-change="set_llm" class="flex items-center gap-2 text-xs text-zinc-500">
        <span>{gettext("Model")}</span>
        <select
          name="alias"
          class="rounded-md border border-zinc-300 bg-white px-2 py-1 text-xs focus:border-primary-500 focus:ring-1 focus:ring-primary-500"
        >
          <option value="" selected={is_nil(@session && @session.llm_alias)}>{gettext("echo (demo)")}</option>
          <option
            :for={llm <- @available_llms}
            value={llm.alias}
            selected={@session && @session.llm_alias == llm.alias}
          >
            {llm_label(llm)}
          </option>
        </select>
      </form>
      <Button.icon_button
        phx-click="toggle_memory"
        color="gray"
        title={if @memory_open?, do: gettext("Hide memory"), else: gettext("Show memory")}
      >
        <.icon name="hero-bars-4" class="size-5" />
      </Button.icon_button>
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
      <Button.icon_button type="submit" color="primary" size="xs" title={gettext("Save (Enter)")}>
        <.icon name="hero-check" class="size-4" />
      </Button.icon_button>
      <Button.icon_button
        type="button"
        phx-click="cancel_title"
        color="gray"
        size="xs"
        title={gettext("Cancel (Esc)")}
      >
        <.icon name="hero-x-mark" class="size-4" />
      </Button.icon_button>
    </form>
    """
  end

  defp session_title(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="edit_title"
      class="font-semibold truncate hover:bg-zinc-100 px-2 py-0.5 rounded transition text-left max-w-md"
      title={gettext("Click to rename")}
    >
      {(@session && @session.title) || "—"}
    </button>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="h-full flex flex-col items-center justify-center text-center text-zinc-400 py-20">
      <.icon name="hero-chat-bubble-left-right" class="size-14 mb-4 text-zinc-300" />
      <div class="text-zinc-500 font-medium">{gettext("Start a conversation")}</div>
      <div class="text-xs mt-1.5 max-w-xs">
        {gettext("Type a message below. The agent has access to file I/O, code execution, memory, HTTP fetch, and browser tools.")}
      </div>
    </div>
    """
  end

  attr :attachments, :list, required: true
  attr :session_id, :string, required: true
  attr :dark?, :boolean, default: false

  defp attachment_list(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2 mt-2">
      <%= for a <- @attachments do %>
        <a
          :if={a["kind"] == "image"}
          href={media_url(@session_id, a["file"])}
          target="_blank"
          class="block"
        >
          <img
            src={media_url(@session_id, a["file"])}
            title={a["caption"]}
            class={["max-h-52 max-w-[240px] rounded-lg border", (@dark? && "border-white/40") || "border-zinc-200"]}
          />
        </a>
        <video
          :if={a["kind"] == "video"}
          src={media_url(@session_id, a["file"])}
          controls
          class={["max-h-52 max-w-[240px] rounded-lg border", (@dark? && "border-white/40") || "border-zinc-200"]}
        />
        <a
          :if={a["kind"] not in ["image", "video"]}
          href={media_url(@session_id, a["file"])}
          target="_blank"
          class={[
            "px-3 py-1.5 rounded-lg text-xs flex items-center gap-1.5",
            (@dark? && "bg-white/20") || "bg-zinc-100 text-zinc-700"
          ]}
        >
          <.icon name="hero-document" class="size-4" />{a["caption"] || a["file"]}
        </a>
      <% end %>
    </div>
    """
  end

  attr :msg, :any, required: true

  defp message_bubble(%{msg: %{role: :user}} = assigns) do
    assigns =
      assigns
      |> assign(:body, attachment_text(assigns.msg))
      |> assign(:attachments, attachments_of(assigns.msg))

    ~H"""
    <div class="flex justify-end">
      <div class="max-w-[75%] rounded-2xl bg-primary-600 px-4 py-2.5 text-[15px] leading-relaxed text-white">
        <div :if={@body != ""} class="whitespace-pre-wrap break-words">{@body}</div>
        <.attachment_list
          :if={@attachments != []}
          attachments={@attachments}
          session_id={@msg.session_id}
          dark?={true}
        />
      </div>
    </div>
    """
  end

  defp message_bubble(%{msg: %{role: :assistant}} = assigns) do
    assigns = assign(assigns, :attachments, attachments_of(assigns.msg))

    ~H"""
    <div class="flex justify-start">
      <div class="max-w-[85%] rounded-2xl border border-zinc-200 bg-white px-4 py-3 text-[15px] leading-relaxed shadow-sm">
        <.attachment_list
          :if={@attachments != []}
          attachments={@attachments}
          session_id={@msg.session_id}
          dark?={false}
        />
        <div :if={(@msg.content || "") != ""} class="whitespace-pre-wrap break-words">
          {format_text(@msg.content)}
        </div>
        <.tool_call_list :if={(@msg.tool_calls || []) != []} tool_calls={@msg.tool_calls} />
      </div>
    </div>
    """
  end

  defp message_bubble(assigns), do: ~H""

  attr :tool_calls, :list, required: true

  defp tool_call_list(assigns) do
    ~H"""
    <div class="mt-3 space-y-1.5">
      <details :for={tc <- @tool_calls} class="group">
        <summary class="cursor-pointer text-xs text-zinc-600 hover:text-zinc-900 select-none flex items-center gap-2">
          <Badge.badge color="gray" size="xs">
            <span class="inline-flex items-center gap-1">
              <.icon name="hero-wrench-screwdriver" class="size-3" />{tc["name"]}
            </span>
          </Badge.badge>
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
    <div class="flex justify-start">
      <div class="max-w-[85%] rounded-2xl border border-zinc-200 bg-white px-4 py-3 text-[15px] leading-relaxed shadow-sm">
        <details :if={@streaming.thinking != ""} class="mb-2">
          <summary class="cursor-pointer text-xs text-zinc-400">{gettext("thinking…")}</summary>
          <pre class="mt-1.5 text-xs text-zinc-500 whitespace-pre-wrap leading-snug">{@streaming.thinking}</pre>
        </details>
        <div :if={@streaming.text != ""} class="whitespace-pre-wrap break-words leading-relaxed">
          {format_text(@streaming.text)}<span class="inline-block w-2 h-4 ml-0.5 align-middle bg-zinc-400 animate-pulse rounded-sm" />
        </div>
        <div
          :if={@streaming.text == "" and @streaming.tool_runs == []}
          class="flex items-center gap-2 text-sm text-zinc-400"
        >
          <.icon name="hero-arrow-path" class="size-4 animate-spin" /> {gettext("thinking")}
        </div>
        <.tool_run_card :for={run <- @streaming.tool_runs} run={run} />
      </div>
    </div>
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
    <div class="mt-3 rounded-lg border border-zinc-200 bg-zinc-50/50 overflow-hidden">
      <div class="px-3 py-2 flex items-center justify-between text-xs">
        <Badge.badge color="gray" size="xs">
          <span class="inline-flex items-center gap-1">
            <.icon name="hero-wrench-screwdriver" class="size-3" />{@run.name}
          </span>
        </Badge.badge>
        <Badge.badge color={@badge_color} size="xs" class={@pulse? && "animate-pulse"}>
          {@badge_label}
        </Badge.badge>
      </div>
      <details class="px-3 pb-2 text-[11px] text-zinc-500">
        <summary class="cursor-pointer">{gettext("args")}</summary>
        <pre class="mt-1 bg-white border border-zinc-200 rounded p-2 overflow-x-auto leading-snug font-mono text-zinc-700">{format_data(@run.args || %{})}</pre>
      </details>
      <pre
        :if={@run.output != ""}
        class="mx-3 mb-2 text-[11px] bg-zinc-900 text-zinc-100 rounded p-2 overflow-x-auto whitespace-pre-wrap break-words leading-snug font-mono"
      >{@run.output}</pre>
      <details :if={@run.data != nil} class="px-3 pb-2 text-[11px] text-zinc-500">
        <summary class="cursor-pointer">{gettext("result")}</summary>
        <pre class="mt-1 bg-white border border-zinc-200 rounded p-2 overflow-x-auto leading-snug font-mono text-zinc-700">{format_data(@run.data)}</pre>
      </details>
    </div>
    """
  end

  attr :notice, :map, required: true

  defp loop_notice(assigns) do
    assigns = assign(assigns, :classes, notice_classes(assigns.notice.kind))

    ~H"""
    <div class={["max-w-2xl mx-auto rounded-xl border px-4 py-3 text-sm", @classes]}>
      <div class="flex items-start gap-3">
        <div class="flex-1">{@notice.text}</div>
        <button
          type="button"
          phx-click="dismiss_notice"
          class="text-xs underline opacity-70 hover:opacity-100"
        >
          {gettext("dismiss")}
        </button>
      </div>
    </div>
    """
  end

  attr :ask, :map, required: true

  defp ask_user_card(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto rounded-xl border border-amber-200 bg-amber-50 px-4 py-3">
      <div class="text-sm font-semibold text-amber-900 mb-2 flex items-center gap-1.5">
        <.icon name="hero-question-mark-circle" class="size-4" />{gettext("The agent is asking")}
      </div>
      <p class="mb-3 text-amber-900">{@ask["question"]}</p>
      <form phx-submit="answer_ask_user" class="flex gap-2 mb-3">
        <input
          name="answer"
          autofocus
          class="flex-1 border border-amber-300 rounded-lg px-3 py-2 bg-white focus:ring-2 focus:ring-amber-400 outline-none"
          placeholder={gettext("Type your answer…")}
        />
        <Button.button type="submit" color="warning" radius="lg" size="sm">{gettext("Send")}</Button.button>
      </form>
      <div :if={(@ask["candidates"] || []) != []} class="flex gap-2 flex-wrap">
        <Button.button
          :for={c <- @ask["candidates"]}
          phx-click="answer_ask_user"
          phx-value-answer={c}
          size="xs"
          radius="full"
          variant="outline"
          color="warning"
        >
          {c}
        </Button.button>
      </div>
    </div>
    """
  end

  attr :loop_running?, :boolean, required: true
  attr :uploads, :any, required: true

  defp composer(assigns) do
    ~H"""
    <form
      id="composer"
      phx-submit="submit"
      phx-change="validate_upload"
      phx-hook=".Composer"
      phx-drop-target={@uploads.attachments.ref}
      class="border-t border-zinc-200 bg-white px-4 sm:px-6 py-3"
    >
      <div class="max-w-4xl mx-auto">
        <div :if={@uploads.attachments.entries != []} class="flex flex-wrap gap-3 mb-3">
          <div :for={entry <- @uploads.attachments.entries} class="relative group">
            <.live_img_preview
              :if={image_entry?(entry)}
              entry={entry}
              class="h-16 w-16 object-cover rounded-lg border border-zinc-200"
            />
            <div
              :if={!image_entry?(entry)}
              class="h-16 px-3 flex items-center gap-1.5 rounded-lg border border-zinc-200 bg-zinc-50 text-xs text-zinc-600 max-w-[180px]"
            >
              <.icon name="hero-document" class="size-4 shrink-0 text-zinc-400" />
              <span class="truncate">{entry.client_name}</span>
            </div>
            <button
              type="button"
              phx-click="cancel_upload"
              phx-value-ref={entry.ref}
              class="absolute -top-1.5 -right-1.5 size-5 rounded-full bg-zinc-700 text-white text-sm leading-none flex items-center justify-center opacity-0 group-hover:opacity-100 transition"
              title="Remove"
            >
              ×
            </button>
            <p
              :for={err <- upload_errors(@uploads.attachments, entry)}
              class="absolute -bottom-4 left-0 text-[10px] text-red-500 whitespace-nowrap"
            >
              {upload_error_to_string(err)}
            </p>
          </div>
        </div>

        <div class="flex items-end gap-2">
          <label
            class="shrink-0 size-[50px] flex items-center justify-center rounded-2xl border border-zinc-300 text-zinc-500 hover:bg-zinc-50 cursor-pointer"
            title={gettext("Attach images or files")}
          >
            <.icon name="hero-paper-clip" class="size-5" />
            <.live_file_input upload={@uploads.attachments} class="hidden" />
          </label>

          <textarea
            name="input"
            rows="1"
            placeholder={
              if @loop_running?,
                do: gettext("Working…"),
                else: gettext("Send a message  (Enter to send · Shift+Enter for newline)")
            }
            class="flex-1 resize-none border border-zinc-300 rounded-2xl px-4 py-3 leading-relaxed bg-white focus:ring-2 focus:ring-primary-500 focus:border-transparent outline-none max-h-60"
            autofocus
          ></textarea>

          <Button.icon_button
            type="submit"
            disabled={@loop_running?}
            color={if @loop_running?, do: "gray", else: "primary"}
            radius="full"
            class="!h-[50px] !w-[50px] shrink-0"
            title={gettext("Send")}
          >
            <.icon
              name={if @loop_running?, do: "hero-arrow-path", else: "hero-paper-airplane"}
              class={["size-5", @loop_running? && "animate-spin"]}
            />
          </Button.icon_button>
        </div>
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
        <div class="rounded-lg border border-zinc-200 bg-white p-3">
          <div class="text-[11px] font-medium uppercase text-zinc-500 mb-1">{gettext("L1 · Working memory")}</div>
          <pre class="text-xs whitespace-pre-wrap text-zinc-700 leading-snug min-h-[1.5em]">{(@checkpoint && @checkpoint.key_info) || gettext("(empty)")}</pre>
        </div>

        <div class="rounded-lg border border-zinc-200 bg-white p-3">
          <div class="text-[11px] font-medium uppercase text-zinc-500 mb-1">{gettext("L2 · Global memory")}</div>
          <p :if={@global_memory == []} class="text-xs text-zinc-400">{gettext("(empty)")}</p>
          <ul :if={@global_memory != []} class="space-y-2 text-xs">
            <li :for={entry <- @global_memory} class="border-l-2 border-zinc-200 pl-2.5">
              <div class="text-[10px] uppercase tracking-wide text-zinc-400">{entry.scope}</div>
              <div class="font-medium text-zinc-700">{entry.key}</div>
              <div class="text-zinc-500 leading-snug">{entry.value}</div>
            </li>
          </ul>
        </div>
      </div>
    </aside>
    """
  end

  # ── Attachments (web /chat multimodal uploads) ───────────────────────

  # Move this turn's uploaded files out of the temp area into the session's
  # web_inbox (under the workspace root so the agent's file tools can read
  # them) and return their absolute paths.
  defp consume_attachments(socket) do
    sid = socket.assigns.session_id

    consume_uploaded_entries(socket, :attachments, fn %{path: tmp}, entry ->
      {:ok, Agent.stage_in_web_inbox(sid, tmp, entry.client_name)}
    end)
  end

  defp image_entry?(%{client_type: "image/" <> _}), do: true
  defp image_entry?(%{client_name: name}) when is_binary(name), do: Agent.image?(name)
  defp image_entry?(_), do: false

  defp media_url(session_id, file), do: ~p"/chat/media/#{session_id}/#{file}"

  defp attachments_of(%{blocks: %{"attachments" => atts}}) when is_list(atts), do: atts
  defp attachments_of(_), do: []

  defp attachment_text(%{content: content}), do: strip_attachment_note(content)
  defp attachment_text(_), do: ""

  # Undo the "[attachments: …]" suffix Server.display_text_for/2 appends to
  # the stored content — the bubble shows the files as thumbnails/chips.
  defp strip_attachment_note(nil), do: ""

  defp strip_attachment_note(text),
    do: String.replace(text, ~r/\n\[attachments:[^\]]*\]\s*\z/, "")

  defp upload_error_to_string(:too_large), do: gettext("too large (max 25MB)")
  defp upload_error_to_string(:too_many_files), do: gettext("too many files")
  defp upload_error_to_string(:not_accepted), do: gettext("type not accepted")
  defp upload_error_to_string(other), do: to_string(other)
end
