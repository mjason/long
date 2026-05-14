defmodule LongWeb.AgentLive.Chat do
  @moduledoc """
  Phase 6 — the LiveView the user interacts with. Subscribes to the
  session's PubSub topic, renders streaming LLM output and tool runs in
  real time, and surfaces the L1/L2 memory in the right rail.
  """

  use LongWeb, :live_view

  alias Long.Agent
  alias Long.Agent.SessionRunner

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
     |> assign(:tool_runs, %{})
     |> assign(:tool_order, [])
     |> assign(:streaming, nil)
     |> assign(:loop_running?, false)
     |> assign(:available_llms, list_llms())
     |> assign(:checkpoint, load_checkpoint(session_id))
     |> assign(:global_memory, load_global_memory())
     |> assign(:ask_user, nil)
     |> assign(:user_input, "")
     |> assign(:sessions, list_sessions())}
  end

  @impl true
  def handle_event("submit", %{"input" => text}, socket) when byte_size(text) > 0 do
    SessionRunner.send_user_message(socket.assigns.session_id, text)

    {:noreply,
     socket
     |> assign(:user_input, "")
     |> assign(:loop_running?, true)
     |> assign(:tool_runs, %{})
     |> assign(:tool_order, [])
     |> assign(:streaming, %{text: "", thinking: ""})}
  end

  def handle_event("submit", _, socket), do: {:noreply, socket}

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

  def handle_info({:message_persisted, %{message: _msg}}, socket) do
    {:noreply, assign(socket, :messages, load_messages(socket.assigns.session_id))}
  end

  def handle_info({:turn_start, _n}, socket) do
    {:noreply, assign(socket, :streaming, %{text: "", thinking: ""})}
  end

  def handle_info({:llm_chunk, t}, socket) do
    s = socket.assigns.streaming || %{text: "", thinking: ""}
    {:noreply, assign(socket, :streaming, %{s | text: s.text <> t})}
  end

  def handle_info({:llm_thinking, t}, socket) do
    s = socket.assigns.streaming || %{text: "", thinking: ""}
    {:noreply, assign(socket, :streaming, %{s | thinking: s.thinking <> t})}
  end

  def handle_info({:llm_done, _resp}, socket) do
    {:noreply, assign(socket, :streaming, nil)}
  end

  def handle_info({:tool_start, %{id: id, name: name, args: args}}, socket) do
    run = %{id: id, name: name, args: args, output: "", data: nil, status: :running}

    {:noreply,
     socket
     |> assign(:tool_runs, Map.put(socket.assigns.tool_runs, id, run))
     |> assign(:tool_order, socket.assigns.tool_order ++ [id])}
  end

  def handle_info({:tool_output, t}, socket) do
    tool_runs =
      Map.new(socket.assigns.tool_runs, fn
        {id, %{status: :running} = run} -> {id, %{run | output: run.output <> t}}
        kv -> kv
      end)

    {:noreply, assign(socket, :tool_runs, tool_runs)}
  end

  def handle_info({:tool_done, %{id: id, data: data}}, socket) do
    tool_runs =
      Map.update(socket.assigns.tool_runs, id, %{}, fn run ->
        %{run | status: :done, data: data}
      end)

    {:noreply, assign(socket, :tool_runs, tool_runs)}
  end

  def handle_info({:ask_user, payload}, socket),
    do: {:noreply, assign(socket, :ask_user, payload)}

  def handle_info({:done, _reason}, socket), do: {:noreply, socket}

  def handle_info({:loop_error, _msg}, socket),
    do: {:noreply, assign(socket, :loop_running?, false)}

  def handle_info(_, socket), do: {:noreply, socket}

  # ── Helpers ──────────────────────────────────────────────────────────────

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

  defp load_messages(session_id) do
    case Agent.list_messages() do
      {:ok, all} ->
        all
        |> Enum.filter(&(&1.session_id == session_id))
        |> Enum.sort_by(&{&1.turn, &1.inserted_at})

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

  # ── Template ─────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-zinc-50 text-sm">
      <aside class="w-56 border-r bg-white flex flex-col">
        <div class="p-3 border-b">
          <button
            phx-click="new_session"
            class="w-full px-3 py-2 rounded bg-zinc-900 text-white hover:bg-zinc-700"
          >
            + New session
          </button>
        </div>
        <ul class="flex-1 overflow-y-auto">
          <li
            :for={s <- @sessions}
            phx-click="switch_session"
            phx-value-id={s.id}
            class={[
              "p-3 border-b cursor-pointer hover:bg-zinc-100",
              s.id == @session_id && "bg-zinc-100 font-medium"
            ]}
          >
            <div class="truncate">{s.title}</div>
            <div class="text-xs text-zinc-500">
              {s.status} · {Calendar.strftime(s.inserted_at, "%m-%d %H:%M")}
            </div>
          </li>
        </ul>
      </aside>

      <main class="flex-1 flex flex-col">
        <header class="border-b bg-white p-3 flex items-center gap-3">
          <div class="font-semibold">{(@session && @session.title) || "—"}</div>
          <div class="flex-1" />
          <label class="text-xs text-zinc-500">Model:</label>
          <form phx-change="set_llm">
            <select name="alias" class="border rounded px-2 py-1 text-xs">
              <option value="" selected={is_nil(@session && @session.llm_alias)}>
                echo (demo, no key)
              </option>
              <option
                :for={llm <- @available_llms}
                value={llm.alias}
                selected={@session && @session.llm_alias == llm.alias}
              >
                {llm.alias} ({llm.kind} · {llm.model})
              </option>
            </select>
          </form>
        </header>

        <div class="flex-1 overflow-y-auto p-4 space-y-3" id="thread" phx-hook="ScrollBottom">
          <article :for={msg <- @messages} class={msg_class(msg.role)}>
            <div class="font-semibold uppercase text-xs text-zinc-500 mb-1">{msg.role}</div>
            <pre class="whitespace-pre-wrap break-words">{msg.content}</pre>

            <ul
              :if={msg.tool_calls && msg.tool_calls != []}
              class="mt-2 text-xs text-zinc-600 space-y-1"
            >
              <li :for={tc <- msg.tool_calls}>
                ↳ <span class="font-mono">{tc["name"]}</span>({truncate(
                  Jason.encode!(tc["input"] || %{}),
                  100
                )})
              </li>
            </ul>
          </article>

          <article
            :for={run <- ordered_runs(@tool_order, @tool_runs)}
            class="border rounded bg-amber-50 p-3"
          >
            <div class="flex items-center justify-between mb-2">
              <span class="font-mono text-xs">🛠 {run.name}</span>
              <span class={status_class(run.status)}>{status_label(run.status)}</span>
            </div>
            <details>
              <summary class="cursor-pointer text-xs text-zinc-500">args</summary>
              <pre class="text-xs whitespace-pre-wrap">{Jason.encode!(run.args || %{}, pretty: true)}</pre>
            </details>
            <pre
              :if={run.output != ""}
              class="text-xs bg-zinc-900 text-zinc-100 p-2 mt-2 rounded whitespace-pre-wrap break-words"
            >{run.output}</pre>
            <details :if={run.data != nil}>
              <summary class="cursor-pointer text-xs text-zinc-500 mt-1">result</summary>
              <pre class="text-xs whitespace-pre-wrap">{format_data(run.data)}</pre>
            </details>
          </article>

          <article
            :if={@streaming && (@streaming.text != "" || @streaming.thinking != "")}
            class={msg_class(:assistant)}
          >
            <div class="font-semibold uppercase text-xs text-zinc-500 mb-1">assistant</div>
            <details :if={@streaming.thinking != ""} class="mb-2">
              <summary class="cursor-pointer text-xs text-zinc-500">thinking</summary>
              <pre class="text-xs whitespace-pre-wrap text-zinc-500">{@streaming.thinking}</pre>
            </details>
            <pre class="whitespace-pre-wrap break-words">{@streaming.text}<span class="animate-pulse">▮</span></pre>
          </article>

          <article :if={@ask_user} class="border-2 border-amber-500 rounded p-3 bg-amber-50">
            <div class="font-semibold mb-2">The agent asks:</div>
            <p class="mb-3">{@ask_user["question"]}</p>
            <form phx-submit="answer_ask_user" class="flex gap-2">
              <input name="answer" class="flex-1 border rounded px-2 py-1" autofocus />
              <button type="submit" class="px-3 py-1 bg-amber-600 text-white rounded">Send</button>
            </form>
            <div
              :if={@ask_user["candidates"] && @ask_user["candidates"] != []}
              class="mt-2 flex gap-2 flex-wrap"
            >
              <button
                :for={c <- @ask_user["candidates"]}
                phx-click="answer_ask_user"
                phx-value-answer={c}
                class="text-xs px-2 py-1 bg-white border rounded hover:bg-zinc-100"
              >
                {c}
              </button>
            </div>
          </article>
        </div>

        <form phx-submit="submit" class="border-t bg-white p-3 flex gap-2">
          <input
            name="input"
            value={@user_input}
            placeholder={if @loop_running?, do: "Working…", else: "Type a message"}
            autocomplete="off"
            disabled={@loop_running?}
            class="flex-1 border rounded px-3 py-2"
            id="composer-input"
          />
          <button
            type="submit"
            disabled={@loop_running?}
            class="px-4 py-2 rounded bg-zinc-900 text-white disabled:bg-zinc-400"
          >
            {if @loop_running?, do: "...", else: "Send"}
          </button>
        </form>
      </main>

      <aside class="w-72 border-l bg-white p-4 overflow-y-auto">
        <h3 class="text-xs uppercase font-semibold text-zinc-500 mb-2">L1 · Working memory</h3>
        <pre class="text-xs bg-zinc-50 p-2 rounded whitespace-pre-wrap mb-4">{(@checkpoint && @checkpoint.key_info) || "(empty)"}</pre>

        <h3 class="text-xs uppercase font-semibold text-zinc-500 mb-2">L2 · Global memory</h3>
        <p :if={@global_memory == []} class="text-xs text-zinc-400">(empty)</p>
        <ul :if={@global_memory != []} class="space-y-2 text-xs">
          <li :for={entry <- @global_memory}>
            <div class="text-zinc-500">[{entry.scope}]</div>
            <div><strong>{entry.key}</strong>: {entry.value}</div>
          </li>
        </ul>
      </aside>
    </div>
    """
  end

  defp msg_class(:user), do: "bg-blue-50 border border-blue-200 rounded p-3"
  defp msg_class(:assistant), do: "bg-white border border-zinc-200 rounded p-3"
  defp msg_class(:tool), do: "bg-zinc-100 border rounded p-3 text-xs"
  defp msg_class(_), do: "bg-zinc-50 border rounded p-3"

  defp status_class(:running), do: "text-amber-600 text-xs animate-pulse"
  defp status_class(:done), do: "text-emerald-600 text-xs"
  defp status_class(_), do: "text-zinc-500 text-xs"

  defp status_label(:running), do: "running…"
  defp status_label(:done), do: "✓ done"
  defp status_label(s), do: to_string(s)

  defp truncate(s, n) when byte_size(s) > n, do: binary_part(s, 0, n) <> "…"
  defp truncate(s, _), do: s

  defp format_data(d) when is_binary(d), do: d
  defp format_data(d), do: Jason.encode!(d, pretty: true)

  defp ordered_runs(order, runs) do
    order
    |> Enum.map(&Map.get(runs, &1))
    |> Enum.reject(&is_nil/1)
  end
end
