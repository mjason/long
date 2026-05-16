defmodule LongWeb.ManageLive do
  @moduledoc """
  Unified admin / configuration surface, replacing the ash_admin path
  for day-to-day operator work. Each section is selected by
  `:live_action`:

    * `:llms` — list / create / edit / set-default / delete LLM configs
    * `:memories` — list / delete L1 working checkpoint + L2 global +
      L2 session memory rows
    * `:skills` — read-only browser over `Long.Agent.Skill.Store`, with
      a reindex button

  All UI runs through the Mishka component library; do not write raw
  HTML for things the library already covers.
  """

  use LongWeb, :live_view

  import LongWeb.Components.Alert, only: [flash_group: 1]

  alias Long.Agent
  alias Long.Agent.LLMConfig
  alias Long.Agent.Skill.Store, as: SkillStore
  alias Long.Util.Text

  @sections [
    {:llms, "LLMs", "hero-cpu-chip"},
    {:memories, "Memories", "hero-bookmark"},
    {:skills, "Skills", "hero-puzzle-piece"},
    {:sessions, "Sessions", "hero-chat-bubble-left-right"},
    {:search, "Search", "hero-magnifying-glass"},
    {:credentials, "Credentials", "hero-key"},
    {:scheduled, "Scheduled", "hero-clock"}
  ]

  @memory_kinds ~w(fact preference goal decision)
  @memory_scopes ~w(general insight)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:sections, @sections)
     |> assign(:editing, nil)
     |> assign(:llms, [])
     |> assign(:globals, [])
     |> assign(:session_memories, [])
     |> assign(:checkpoints, [])
     |> assign(:skills, [])}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    section = socket.assigns.live_action || :llms

    {:noreply,
     socket
     |> assign(:section, section)
     |> assign(:editing, nil)
     |> load_section(section)}
  end

  # ── Loaders ──────────────────────────────────────────────────────────

  defp load_section(socket, :llms) do
    rows =
      case Agent.list_llms() do
        {:ok, l} -> Enum.sort_by(l, &{&1.sort_order, &1.alias})
        _ -> []
      end

    assign(socket, :llms, rows)
  end

  defp load_section(socket, :memories) do
    globals =
      case Agent.list_global_memory() do
        {:ok, rows} -> Enum.sort_by(rows, &{&1.scope, &1.key})
        _ -> []
      end

    sessions =
      case Agent.list_session_memory() do
        {:ok, rows} -> Enum.sort_by(rows, &{&1.session_id, &1.key})
        _ -> []
      end

    checkpoints =
      with {:ok, sess_rows} <- Agent.list_sessions(),
           {:ok, cp_rows} <- Agent.list_checkpoints() do
        sessions_by_id = Map.new(sess_rows, &{&1.id, &1})

        cp_rows
        |> Enum.flat_map(fn cp ->
          case sessions_by_id[cp.session_id] do
            nil -> []
            s -> [%{session: s, checkpoint: cp}]
          end
        end)
      else
        _ -> []
      end

    socket
    |> assign(:globals, globals)
    |> assign(:session_memories, sessions)
    |> assign(:checkpoints, checkpoints)
  end

  defp load_section(socket, :skills) do
    assign(socket, :skills, SkillStore.list_all())
  end

  defp load_section(socket, _), do: socket

  # ── Events: LLMs ─────────────────────────────────────────────────────

  @impl true
  def handle_event("new_llm", _params, socket) do
    blank = %{
      alias: "",
      provider: "openai",
      wire_protocol: "openai_chat",
      model: "",
      api_base: "",
      api_key: "",
      api_key_env_var: "",
      enabled: true,
      default: false,
      kind: :openai,
      __action__: :create
    }

    {:noreply, assign(socket, :editing, blank)}
  end

  def handle_event("edit_llm", %{"alias" => name}, socket) do
    case Agent.get_llm(name) do
      {:ok, row} ->
        {:noreply, assign(socket, :editing, llm_to_form(row))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _, socket), do: {:noreply, assign(socket, :editing, nil)}

  def handle_event("save_llm", %{"llm" => params}, socket) do
    attrs = sanitize_llm_attrs(params, socket.assigns.editing.__action__)

    case Agent.register_llm(attrs) do
      {:ok, _row} ->
        {:noreply, socket |> assign(:editing, nil) |> load_section(:llms)}

      {:error, err} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(err)}")}
    end
  end

  def handle_event("set_default_llm", %{"alias" => name}, socket) do
    case Agent.set_default_llm(name) do
      {:ok, _} -> {:noreply, load_section(socket, :llms)}
      {:error, e} -> {:noreply, put_flash(socket, :error, "Set-default failed: #{inspect(e)}")}
    end
  end

  def handle_event("toggle_llm_enabled", %{"alias" => name}, socket) do
    with {:ok, row} <- Agent.get_llm(name),
         {:ok, _} <- Agent.update_llm(row, %{enabled: !row.enabled}) do
      {:noreply, load_section(socket, :llms)}
    else
      {:error, e} -> {:noreply, put_flash(socket, :error, "Toggle failed: #{inspect(e)}")}
    end
  end

  def handle_event("destroy_llm", %{"alias" => name}, socket) do
    with {:ok, row} <- Agent.get_llm(name),
         :ok <- Agent.destroy_llm(row) do
      {:noreply, load_section(socket, :llms)}
    else
      {:ok, _} -> {:noreply, load_section(socket, :llms)}
      {:error, e} -> {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(e)}")}
    end
  end

  # ── Events: Memories ─────────────────────────────────────────────────

  def handle_event("destroy_global_memory", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.globals, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      row ->
        case Agent.delete_global_memory(row) do
          :ok -> {:noreply, load_section(socket, :memories)}
          {:ok, _} -> {:noreply, load_section(socket, :memories)}
          {:error, e} -> {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(e)}")}
        end
    end
  end

  def handle_event("destroy_session_memory", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.session_memories, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      row ->
        case Agent.delete_session_memory(row) do
          :ok -> {:noreply, load_section(socket, :memories)}
          {:ok, _} -> {:noreply, load_section(socket, :memories)}
          {:error, e} -> {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(e)}")}
        end
    end
  end

  def handle_event("clear_checkpoint", %{"session_id" => sid}, socket) do
    case Agent.upsert_checkpoint(%{session_id: sid, key_info: ""}) do
      {:ok, _} -> {:noreply, load_section(socket, :memories)}
      {:error, e} -> {:noreply, put_flash(socket, :error, "Clear failed: #{inspect(e)}")}
    end
  end

  def handle_event("edit_global_memory", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.globals, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      row ->
        editing = %{
          __action__: :edit_global,
          id: row.id,
          scope: to_string(row.scope),
          key: row.key,
          value: row.value,
          kind: to_string(row.kind || :fact),
          importance: row.importance || 3
        }

        {:noreply, assign(socket, :editing, editing)}
    end
  end

  def handle_event("save_global_memory", %{"memory" => params}, socket) do
    # `to_existing_atom` blocks the `params -> atom` exhaustion vector;
    # the schema's `one_of` constraints have already loaded these atoms.
    attrs = %{
      scope: safe_atom(params["scope"], :general, @memory_scopes),
      key: String.trim(params["key"] || ""),
      value: params["value"] || "",
      kind: safe_atom(params["kind"], :fact, @memory_kinds),
      importance: parse_int(params["importance"], 3)
    }

    case Agent.put_global_memory(attrs) do
      {:ok, _} -> {:noreply, socket |> assign(:editing, nil) |> load_section(:memories)}
      {:error, e} -> {:noreply, put_flash(socket, :error, "Save failed: #{inspect(e)}")}
    end
  end

  # ── Events: Skills ───────────────────────────────────────────────────

  def handle_event("skill_reindex", _, socket) do
    :ok = SkillStore.reindex()
    {:noreply, load_section(socket, :skills) |> put_flash(:info, "Rescanned skill_root.")}
  end

  # ── Template ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-zinc-50 text-zinc-900">
      <aside class="w-56 border-r border-zinc-200 bg-white flex flex-col shrink-0">
        <div class="p-4 border-b border-zinc-200">
          <div class="font-semibold text-zinc-900">Long · Manage</div>
          <.button_link
            navigate={~p"/chat"}
            variant="base"
            color="natural"
            size="extra_small"
            icon="hero-arrow-left"
            rounded="medium"
            class="!mt-2"
          >
            Back to chat
          </.button_link>
        </div>
        <nav class="flex-1 overflow-y-auto p-2 space-y-0.5">
          <.button_link
            :for={{key, label, icon} <- @sections}
            navigate={section_path(key)}
            variant={if @section == key, do: "default", else: "base"}
            color={if @section == key, do: "primary", else: "natural"}
            size="small"
            rounded="medium"
            icon={icon}
            full_width
            class="!justify-start"
          >
            {label}
          </.button_link>
        </nav>
      </aside>

      <main class="flex-1 overflow-y-auto">
        <.flash_group flash={@flash} />
        <.section_view {assigns} />
        <.llm_modal
          :if={editing_kind(@editing) == :llm}
          editing={@editing}
          providers={LLMConfig.providers()}
          wire_protocols={LLMConfig.wire_protocols()}
        />
        <.memory_modal
          :if={editing_kind(@editing) == :global_memory}
          editing={@editing}
          scopes={@memory_scopes}
          kinds={@memory_kinds}
        />
      </main>
    </div>
    """
  end

  defp editing_kind(nil), do: nil
  defp editing_kind(%{__action__: a}) when a in [:create, :edit_llm], do: :llm
  defp editing_kind(%{__action__: :edit_global}), do: :global_memory
  defp editing_kind(_), do: nil

  # ── Section views ────────────────────────────────────────────────────

  defp section_view(%{section: :llms} = assigns), do: llm_section(assigns)
  defp section_view(%{section: :memories} = assigns), do: memory_section(assigns)
  defp section_view(%{section: :skills} = assigns), do: skill_section(assigns)
  defp section_view(assigns), do: placeholder(%{title: section_title(assigns.section)})

  defp llm_section(assigns) do
    ~H"""
    <div class="p-6 space-y-4">
      <div class="flex items-center gap-3">
        <h1 class="text-xl font-semibold flex-1">LLM configurations</h1>
        <.button phx-click="new_llm" color="primary" icon="hero-plus" rounded="medium" size="small">
          New LLM
        </.button>
      </div>

      <.card variant="bordered" color="natural" rounded="large" padding="none">
        <table class="w-full text-sm">
          <thead class="text-xs uppercase text-zinc-500 bg-zinc-50">
            <tr>
              <th class="text-left px-4 py-2.5">Alias</th>
              <th class="text-left px-4 py-2.5">Provider</th>
              <th class="text-left px-4 py-2.5">Wire</th>
              <th class="text-left px-4 py-2.5">Model</th>
              <th class="text-left px-4 py-2.5">Status</th>
              <th class="text-right px-4 py-2.5">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={llm <- @llms} class="border-t border-zinc-100">
              <td class="px-4 py-2 font-medium">
                <span class="flex items-center gap-2">
                  <.icon :if={llm.default} name="hero-star-solid" class="size-4 text-amber-500" />
                  {llm.alias}
                </span>
              </td>
              <td class="px-4 py-2 text-zinc-600">
                <.badge
                  color={if llm.provider, do: "info", else: "silver"}
                  size="extra_small"
                  rounded="full"
                  title={
                    if !llm.provider,
                      do: "Legacy row — set `provider` and `wire_protocol` via Edit to use the new runtime path.",
                      else: nil
                  }
                >
                  {display_provider(llm)}
                </.badge>
              </td>
              <td class="px-4 py-2 text-xs text-zinc-500">{llm.wire_protocol || "—"}</td>
              <td class="px-4 py-2 text-zinc-600 font-mono text-xs">{llm.model}</td>
              <td class="px-4 py-2">
                <.badge color={if llm.enabled, do: "success", else: "silver"} size="extra_small" rounded="full">
                  {if llm.enabled, do: "enabled", else: "disabled"}
                </.badge>
              </td>
              <td class="px-4 py-2">
                <div class="flex justify-end gap-1.5">
                  <.button
                    :if={!llm.default}
                    phx-click="set_default_llm"
                    phx-value-alias={llm.alias}
                    variant="base"
                    color="warning"
                    size="extra_small"
                    icon="hero-star"
                    rounded="medium"
                    title="Set as default"
                  />
                  <.button
                    phx-click="toggle_llm_enabled"
                    phx-value-alias={llm.alias}
                    variant="base"
                    color="natural"
                    size="extra_small"
                    icon={if llm.enabled, do: "hero-pause", else: "hero-play"}
                    rounded="medium"
                    title={if llm.enabled, do: "Disable", else: "Enable"}
                  />
                  <.button
                    phx-click="edit_llm"
                    phx-value-alias={llm.alias}
                    variant="base"
                    color="natural"
                    size="extra_small"
                    icon="hero-pencil-square"
                    rounded="medium"
                    title="Edit"
                  />
                  <.button
                    phx-click="destroy_llm"
                    phx-value-alias={llm.alias}
                    variant="base"
                    color="danger"
                    size="extra_small"
                    icon="hero-trash"
                    rounded="medium"
                    data-confirm={"Delete \"#{llm.alias}\"?"}
                    title="Delete"
                  />
                </div>
              </td>
            </tr>
            <tr :if={@llms == []}>
              <td colspan="6" class="px-4 py-8 text-center text-zinc-400 text-sm">
                No LLM configurations yet. Click <strong>New LLM</strong> above to add one.
              </td>
            </tr>
          </tbody>
        </table>
      </.card>
    </div>
    """
  end

  defp memory_section(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <h1 class="text-xl font-semibold">Memory editor</h1>

      <section class="space-y-2">
        <h2 class="text-sm font-semibold text-zinc-700 uppercase tracking-wide">L1 · Working checkpoints</h2>
        <.card variant="bordered" color="natural" rounded="large" padding="none">
          <table class="w-full text-sm">
            <thead class="text-xs uppercase text-zinc-500 bg-zinc-50">
              <tr>
                <th class="text-left px-4 py-2.5">Session</th>
                <th class="text-left px-4 py-2.5">key_info</th>
                <th class="text-right px-4 py-2.5">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @checkpoints} class="border-t border-zinc-100">
                <td class="px-4 py-2 text-xs font-mono text-zinc-500">{row.session.title || row.session.id}</td>
                <td class="px-4 py-2 text-zinc-700 whitespace-pre-wrap leading-snug">{row.checkpoint.key_info}</td>
                <td class="px-4 py-2 text-right">
                  <.button
                    phx-click="clear_checkpoint"
                    phx-value-session_id={row.session.id}
                    variant="base"
                    color="danger"
                    size="extra_small"
                    icon="hero-x-mark"
                    rounded="medium"
                    data-confirm="Clear this session's working checkpoint?"
                  >
                    Clear
                  </.button>
                </td>
              </tr>
              <tr :if={@checkpoints == []}>
                <td colspan="3" class="px-4 py-6 text-center text-zinc-400 text-sm">(no checkpoints)</td>
              </tr>
            </tbody>
          </table>
        </.card>
      </section>

      <section class="space-y-2">
        <h2 class="text-sm font-semibold text-zinc-700 uppercase tracking-wide">L2 · Global memory</h2>
        <.card variant="bordered" color="natural" rounded="large" padding="none">
          <table class="w-full text-sm">
            <thead class="text-xs uppercase text-zinc-500 bg-zinc-50">
              <tr>
                <th class="text-left px-4 py-2.5">Scope</th>
                <th class="text-left px-4 py-2.5">Kind</th>
                <th class="text-left px-4 py-2.5">Key</th>
                <th class="text-left px-4 py-2.5">Value</th>
                <th class="text-left px-4 py-2.5">Imp</th>
                <th class="text-right px-4 py-2.5">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @globals} class="border-t border-zinc-100">
                <td class="px-4 py-2">
                  <.badge color="info" size="extra_small" rounded="full">{row.scope}</.badge>
                </td>
                <td class="px-4 py-2 text-xs text-zinc-500">{row.kind}</td>
                <td class="px-4 py-2 font-medium text-zinc-800">{row.key}</td>
                <td class="px-4 py-2 text-zinc-600 leading-snug">{Text.preview(row.value, 140)}</td>
                <td class="px-4 py-2 text-xs">{row.importance || 3}</td>
                <td class="px-4 py-2 text-right">
                  <div class="flex justify-end gap-1.5">
                    <.button
                      phx-click="edit_global_memory"
                      phx-value-id={row.id}
                      variant="base"
                      color="natural"
                      size="extra_small"
                      icon="hero-pencil-square"
                      rounded="medium"
                    />
                    <.button
                      phx-click="destroy_global_memory"
                      phx-value-id={row.id}
                      variant="base"
                      color="danger"
                      size="extra_small"
                      icon="hero-trash"
                      rounded="medium"
                      data-confirm={"Delete \"#{row.key}\"?"}
                    />
                  </div>
                </td>
              </tr>
              <tr :if={@globals == []}>
                <td colspan="6" class="px-4 py-6 text-center text-zinc-400 text-sm">(no global memory)</td>
              </tr>
            </tbody>
          </table>
        </.card>
      </section>

      <section class="space-y-2">
        <h2 class="text-sm font-semibold text-zinc-700 uppercase tracking-wide">L2 · Session memory</h2>
        <.card variant="bordered" color="natural" rounded="large" padding="none">
          <table class="w-full text-sm">
            <thead class="text-xs uppercase text-zinc-500 bg-zinc-50">
              <tr>
                <th class="text-left px-4 py-2.5">Session</th>
                <th class="text-left px-4 py-2.5">Kind</th>
                <th class="text-left px-4 py-2.5">Key</th>
                <th class="text-left px-4 py-2.5">Value</th>
                <th class="text-right px-4 py-2.5">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @session_memories} class="border-t border-zinc-100">
                <td class="px-4 py-2 text-xs font-mono text-zinc-500">{short(row.session_id)}</td>
                <td class="px-4 py-2 text-xs text-zinc-500">{row.kind}</td>
                <td class="px-4 py-2 font-medium text-zinc-800">{row.key}</td>
                <td class="px-4 py-2 text-zinc-600 leading-snug">{Text.preview(row.value, 140)}</td>
                <td class="px-4 py-2 text-right">
                  <.button
                    phx-click="destroy_session_memory"
                    phx-value-id={row.id}
                    variant="base"
                    color="danger"
                    size="extra_small"
                    icon="hero-trash"
                    rounded="medium"
                    data-confirm={"Delete \"#{row.key}\"?"}
                  />
                </td>
              </tr>
              <tr :if={@session_memories == []}>
                <td colspan="5" class="px-4 py-6 text-center text-zinc-400 text-sm">(no session memory)</td>
              </tr>
            </tbody>
          </table>
        </.card>
      </section>
    </div>
    """
  end

  defp skill_section(assigns) do
    ~H"""
    <div class="p-6 space-y-4">
      <div class="flex items-center gap-3">
        <h1 class="text-xl font-semibold flex-1">Skills</h1>
        <span class="text-xs text-zinc-400 font-mono">{SkillStore.root()}</span>
        <.button
          phx-click="skill_reindex"
          color="primary"
          variant="outline"
          icon="hero-arrow-path"
          rounded="medium"
          size="small"
        >
          Reindex
        </.button>
      </div>

      <.card variant="bordered" color="natural" rounded="large" padding="none">
        <table class="w-full text-sm">
          <thead class="text-xs uppercase text-zinc-500 bg-zinc-50">
            <tr>
              <th class="text-left px-4 py-2.5">Name</th>
              <th class="text-left px-4 py-2.5">Description</th>
              <th class="text-left px-4 py-2.5">Tags</th>
              <th class="text-left px-4 py-2.5">Path</th>
              <th class="text-right px-4 py-2.5">Used</th>
              <th class="text-right px-4 py-2.5">Last used</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={s <- @skills} class="border-t border-zinc-100">
              <td class="px-4 py-2 font-mono text-zinc-800">{s.name}</td>
              <td class="px-4 py-2 text-zinc-600 leading-snug max-w-md">{Text.preview(s.description || "", 120)}</td>
              <td class="px-4 py-2">
                <span class="inline-flex gap-1">
                  <.badge :for={t <- s.tags || []} color="silver" size="extra_small" rounded="full">{t}</.badge>
                </span>
              </td>
              <td class="px-4 py-2 text-xs font-mono text-zinc-500">{s.relative_path}</td>
              <td class="px-4 py-2 text-right text-zinc-600">{s.use_count}</td>
              <td class="px-4 py-2 text-right text-xs text-zinc-500">{format_dt(s.last_used_at)}</td>
            </tr>
            <tr :if={@skills == []}>
              <td colspan="6" class="px-4 py-8 text-center text-zinc-400 text-sm">
                No skills under <code class="text-xs">{SkillStore.root()}</code>. Drop a
                <code class="text-xs">SKILL.md</code> in there and hit <strong>Reindex</strong>.
              </td>
            </tr>
          </tbody>
        </table>
      </.card>
    </div>
    """
  end

  defp placeholder(assigns) do
    ~H"""
    <div class="p-8">
      <h1 class="text-xl font-semibold mb-2">{@title}</h1>
      <p class="text-sm text-zinc-500">Coming soon.</p>
    </div>
    """
  end

  # ── Modals ───────────────────────────────────────────────────────────

  attr :editing, :map, required: true
  attr :providers, :list, required: true
  attr :wire_protocols, :list, required: true

  defp llm_modal(assigns) do
    assigns = assign(assigns, :is_new?, assigns.editing.__action__ == :create)

    ~H"""
    <.modal
      id="llm-edit-modal"
      show
      title={if @is_new?, do: "New LLM configuration", else: "Edit #{@editing.alias}"}
      on_cancel={JS.push("cancel_edit")}
      size="large"
    >
      <form phx-submit="save_llm" class="space-y-3">
        <div class="grid grid-cols-2 gap-3">
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Alias</span>
            <input
              name="llm[alias]"
              value={@editing.alias}
              required
              readonly={!@is_new?}
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm font-mono"
              placeholder="e.g. claude_main"
            />
          </label>
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Model</span>
            <input
              name="llm[model]"
              value={@editing.model}
              required
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm font-mono"
              placeholder="e.g. claude-sonnet-4"
            />
          </label>
        </div>

        <div class="grid grid-cols-2 gap-3">
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Provider</span>
            <select
              name="llm[provider]"
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm"
            >
              <option :for={p <- @providers} value={p} selected={@editing.provider == p}>{p}</option>
            </select>
          </label>
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Wire protocol</span>
            <select
              name="llm[wire_protocol]"
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm"
            >
              <option value="">(provider default)</option>
              <option :for={w <- @wire_protocols} value={w} selected={@editing.wire_protocol == w}>{w}</option>
            </select>
          </label>
        </div>

        <label class="block">
          <span class="text-xs font-medium text-zinc-600">API base URL</span>
          <input
            name="llm[api_base]"
            value={@editing.api_base}
            class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm font-mono"
            placeholder="https://api.anthropic.com"
          />
        </label>

        <div class="grid grid-cols-2 gap-3">
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">API key</span>
            <input
              type="password"
              name="llm[api_key]"
              value={@editing.api_key}
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm font-mono"
              placeholder="sk-…"
            />
          </label>
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">…or env var name</span>
            <input
              name="llm[api_key_env_var]"
              value={@editing.api_key_env_var}
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm font-mono"
              placeholder="ANTHROPIC_API_KEY"
            />
          </label>
        </div>

        <div class="flex items-center gap-6 pt-1">
          <label class="flex items-center gap-2 text-sm text-zinc-700">
            <input type="checkbox" name="llm[enabled]" value="true" checked={@editing.enabled} />
            Enabled
          </label>
          <label class="flex items-center gap-2 text-sm text-zinc-700">
            <input type="checkbox" name="llm[default]" value="true" checked={@editing.default} />
            Set as default
          </label>
        </div>

        <div class="flex justify-end gap-2 pt-2">
          <.button type="button" phx-click="cancel_edit" variant="base" color="natural" rounded="medium" size="small">
            Cancel
          </.button>
          <.button type="submit" color="primary" rounded="medium" size="small">
            Save
          </.button>
        </div>
      </form>
    </.modal>
    """
  end

  attr :editing, :map, required: true
  attr :scopes, :list, required: true
  attr :kinds, :list, required: true

  defp memory_modal(assigns) do
    ~H"""
    <.modal
      id="memory-edit-modal"
      show
      title={"Edit \"#{@editing.key}\""}
      on_cancel={JS.push("cancel_edit")}
      size="medium"
    >
      <form phx-submit="save_global_memory" class="space-y-3">
        <div class="grid grid-cols-2 gap-3">
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Scope</span>
            <select
              name="memory[scope]"
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm"
            >
              <option :for={s <- @scopes} value={s} selected={@editing.scope == s}>{s}</option>
            </select>
          </label>
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Kind</span>
            <select
              name="memory[kind]"
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm"
            >
              <option :for={k <- @kinds} value={k} selected={@editing.kind == k}>{k}</option>
            </select>
          </label>
        </div>
        <label class="block">
          <span class="text-xs font-medium text-zinc-600">Key</span>
          <input
            name="memory[key]"
            value={@editing.key}
            required
            readonly
            class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm font-mono bg-zinc-50"
          />
        </label>
        <label class="block">
          <span class="text-xs font-medium text-zinc-600">Value</span>
          <textarea
            name="memory[value]"
            rows="5"
            class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm leading-snug"
          >{@editing.value}</textarea>
        </label>
        <label class="block w-40">
          <span class="text-xs font-medium text-zinc-600">Importance (1-5)</span>
          <input
            type="number"
            name="memory[importance]"
            value={@editing.importance}
            min="1"
            max="5"
            class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm"
          />
        </label>
        <div class="flex justify-end gap-2 pt-2">
          <.button type="button" phx-click="cancel_edit" variant="base" color="natural" rounded="medium" size="small">
            Cancel
          </.button>
          <.button type="submit" color="primary" rounded="medium" size="small">
            Save
          </.button>
        </div>
      </form>
    </.modal>
    """
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp section_path(:llms), do: ~p"/manage/llms"
  defp section_path(:memories), do: ~p"/manage/memories"
  defp section_path(:skills), do: ~p"/manage/skills"
  defp section_path(:sessions), do: ~p"/manage/sessions"
  defp section_path(:search), do: ~p"/manage/search"
  defp section_path(:credentials), do: ~p"/manage/credentials"
  defp section_path(:scheduled), do: ~p"/manage/scheduled"

  defp section_title(:sessions), do: "Sessions"
  defp section_title(:search), do: "Search providers"
  defp section_title(:credentials), do: "Credentials"
  defp section_title(:scheduled), do: "Scheduled tasks"
  defp section_title(_), do: "—"

  defp llm_to_form(row) do
    %{
      __action__: :edit_llm,
      id: row.id,
      alias: row.alias,
      provider: row.provider || "",
      wire_protocol: row.wire_protocol || "",
      model: row.model || "",
      api_base: row.api_base || "",
      api_key: row.api_key || "",
      api_key_env_var: row.api_key_env_var || "",
      enabled: row.enabled,
      default: row.default,
      kind: row.kind
    }
  end

  # Strip empty strings + checkbox booleans, plus default the legacy
  # `kind` field so register can satisfy its NOT NULL constraint without
  # the form having to expose it.
  defp sanitize_llm_attrs(params, action) do
    base = %{
      alias: String.trim(params["alias"] || ""),
      provider: trim_or_nil(params["provider"]),
      wire_protocol: trim_or_nil(params["wire_protocol"]),
      model: String.trim(params["model"] || ""),
      api_base: trim_or_nil(params["api_base"]),
      api_key: trim_or_nil(params["api_key"]),
      api_key_env_var: trim_or_nil(params["api_key_env_var"]),
      enabled: params["enabled"] == "true",
      default: params["default"] == "true"
    }

    case action do
      :create -> Map.put(base, :kind, kind_for(base.provider))
      _ -> base
    end
  end

  defp trim_or_nil(nil), do: nil

  defp trim_or_nil(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      str -> str
    end
  end

  defp kind_for("anthropic"), do: :claude
  defp kind_for(_), do: :openai

  defp parse_int(nil, default), do: default

  defp parse_int(str, default) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      _ -> default
    end
  end

  defp parse_int(_, default), do: default

  defp short(uuid) when is_binary(uuid), do: String.slice(uuid, 0, 8)
  defp short(_), do: ""

  # Coerce a form-submitted string to an atom in `allowed`; fall back
  # to `default` for missing or unknown values. Uses `to_existing_atom`
  # so a crafted POST can't allocate new atoms.
  defp safe_atom(value, default, allowed) when is_binary(value) do
    if value in allowed, do: String.to_existing_atom(value), else: default
  end

  defp safe_atom(_, default, _), do: default

  defp format_dt(nil), do: "—"

  defp format_dt(%DateTime{} = dt),
    do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp display_provider(%{provider: p}) when is_binary(p) and p != "", do: p
  defp display_provider(%{kind: :claude}), do: "anthropic *"
  defp display_provider(%{kind: :native_claude}), do: "anthropic *"
  defp display_provider(%{kind: :openai}), do: "openai *"
  defp display_provider(%{kind: :native_openai}), do: "openai *"
  defp display_provider(%{kind: :mixin}), do: "mixin *"
  defp display_provider(_), do: "—"
end
