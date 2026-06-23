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

  # Petal Components called qualified during the gradual migration off mishka.
  alias PetalComponents.{Badge, Button}

  alias Long.Agent
  alias Long.Agent.{LLMConfig, SearchConfig}
  alias Long.Agent.Skill.Store, as: SkillStore
  alias Long.Util.Text

  @sections [
    {:llms, "LLMs", "hero-cpu-chip"},
    {:groups, "Groups", "hero-user-group"},
    {:memories, "Memories", "hero-bookmark"},
    {:skills, "Skills", "hero-puzzle-piece"},
    {:sessions, "Sessions", "hero-chat-bubble-left-right"},
    {:search, "Search", "hero-magnifying-glass"},
    {:credentials, "Channels", "hero-signal"},
    {:scheduled, "Scheduled", "hero-clock"},
    {:monitors, "Monitors", "hero-bell-alert"},
    {:reflection, "Reflection", "hero-sparkles"},
    {:secrets, "Secrets", "hero-lock-closed"},
    {:phrases, "Phrases", "hero-language"}
  ]

  # Pull enum values straight from the Ash.Type.Enum modules so the UI
  # pickers can't drift from the schema. `to_string/1` because pickers
  # render strings; the form's cast still converts back to atoms on save.
  defp memory_kinds, do: Enum.map(Long.Agent.Enums.MemoryKind.values(), &Atom.to_string/1)
  defp memory_scopes, do: Enum.map(Long.Agent.Enums.MemoryScope.values(), &Atom.to_string/1)

  defp scheduled_repeats,
    do: Enum.map(Long.Agent.Enums.ScheduledTaskRepeat.values(), &Atom.to_string/1)

  defp member_relations, do: Enum.map(Long.Agent.Enums.MemberRelation.values(), &Atom.to_string/1)
  defp member_roles, do: Enum.map(Long.Agent.Enums.MemberRole.values(), &Atom.to_string/1)

  defp search_providers, do: SearchConfig.providers()

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Long.Agent.Bots.Wechat.Credential.subscribe()
    end

    {:ok,
     socket
     |> assign_new(:locale, fn -> "en" end)
     |> assign(:sections, @sections)
     |> assign(:editing, nil)
     |> assign(:wechat_modal_open?, false)
     |> assign(:wechat_login_name, "default")
     |> assign(:wechat_credentials, [])
     |> assign(:member_options, [])
     |> assign(:llms, [])
     |> assign(:groups, [])
     |> assign(:globals, [])
     |> assign(:session_memories, [])
     |> assign(:checkpoints, [])
     |> assign(:skills, [])
     |> assign(:sessions_rows, [])
     |> assign(:search_configs, [])
     |> assign(:bot_users, [])
     |> assign(:telegram_credentials, [])
     |> assign(:scheduled_tasks, [])
     |> assign(:monitors, [])
     |> assign(:reflection_enabled, true)
     |> assign(:reflection_hour, 18)
     |> assign(:reflection_tasks, [])
     |> assign(:secrets, [])
     |> assign(:phrase_rows, [])}
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

  defp load_section(socket, :groups) do
    rows =
      case Agent.list_groups(load: [members: [:bot_users]]) do
        {:ok, hh} -> Enum.sort_by(hh, & &1.inserted_at, DateTime)
        _ -> []
      end

    assign(socket, :groups, rows)
  end

  defp load_section(socket, :llms) do
    rows =
      case Agent.list_llms() do
        {:ok, l} -> Enum.sort_by(l, & &1.alias)
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
    socket
    |> assign(:skills, SkillStore.list_all())
    |> assign(:skill_owner_names, member_name_map())
  end

  defp load_section(socket, :sessions) do
    rows =
      case Agent.list_sessions() do
        {:ok, list} -> Enum.sort_by(list, & &1.inserted_at, {:desc, DateTime})
        _ -> []
      end

    assign(socket, :sessions_rows, rows)
  end

  defp load_section(socket, :search) do
    rows =
      case Agent.list_search_configs() do
        {:ok, list} -> Enum.sort_by(list, &{&1.sort_order, &1.alias})
        _ -> []
      end

    assign(socket, :search_configs, rows)
  end

  defp load_section(socket, :credentials) do
    bot_users =
      case Agent.list_bot_users() do
        {:ok, list} -> Enum.sort_by(list, &{&1.platform, &1.external_id})
        _ -> []
      end

    wechat =
      case Agent.list_wechat_credentials() do
        {:ok, list} -> Enum.sort_by(list, & &1.name)
        _ -> []
      end

    telegram =
      case Agent.list_telegram_credentials() do
        {:ok, list} -> Enum.sort_by(list, & &1.name)
        _ -> []
      end

    socket
    |> assign(:bot_users, bot_users)
    |> assign(:wechat_credentials, wechat)
    |> assign(:member_options, member_options())
    |> assign(:telegram_credentials, telegram)
  end

  defp load_section(socket, :scheduled) do
    rows =
      case Agent.list_scheduled_tasks() do
        # Silent reflection tasks are system-managed and live on their own
        # /manage/reflection page — keep them out of the user's task list.
        {:ok, list} -> list |> Enum.reject(& &1.silent) |> Enum.sort_by(&sort_key_next_run/1)
        _ -> []
      end

    assign(socket, :scheduled_tasks, rows)
  end

  defp load_section(socket, :monitors) do
    rows =
      case Agent.list_monitors(page: false) do
        {:ok, list} -> Enum.sort_by(list, &sort_key_next_run/1)
        _ -> []
      end

    assign(socket, :monitors, rows)
  end

  defp load_section(socket, :reflection) do
    socket
    |> assign(:reflection_enabled, Agent.reflection_enabled?())
    |> assign(:reflection_hour, Agent.reflection_hour())
    |> assign(:reflection_tasks, Agent.list_reflection_tasks())
  end

  defp load_section(socket, :secrets) do
    rows =
      case Agent.list_secrets() do
        {:ok, list} -> Enum.sort_by(list, & &1.name)
        _ -> []
      end

    assign(socket, :secrets, rows)
  end

  defp load_section(socket, :phrases) do
    overrides =
      case Agent.list_phrases() do
        {:ok, rows} -> Map.new(rows, &{{&1.key, &1.locale}, &1.text})
        _ -> %{}
      end

    rows =
      for key <- Long.Copy.keys(), locale <- Long.Copy.locales() do
        %{
          key: key,
          locale: locale,
          builtin: Long.Copy.builtin(key, locale) || "",
          override: Map.get(overrides, {key, locale}, "")
        }
      end

    assign(socket, :phrase_rows, rows)
  end

  defp load_section(socket, _), do: socket

  # Remove the override row for (key, locale), if any. Returns :ok.
  defp clear_phrase_override(key, locale) do
    with {:ok, rows} <- Agent.list_phrases(),
         %{} = row <- Enum.find(rows, &(&1.key == key and &1.locale == locale)) do
      _ = Agent.destroy_phrase(row)
    end

    :ok
  end

  # member_id → display_name, for labelling personal-skill owners.
  defp member_name_map do
    case Agent.list_members() do
      {:ok, members} -> Map.new(members, &{&1.id, &1.display_name})
      _ -> %{}
    end
  end

  # {id, label} pairs for the per-account member picker on the Channels page.
  defp member_options do
    case Agent.list_members(load: [:group]) do
      {:ok, members} ->
        Enum.map(members, fn m ->
          group = if is_struct(m.group), do: m.group.name, else: "—"
          {m.id, "#{group} · #{m.display_name}"}
        end)

      _ ->
        []
    end
  end

  defp wechat_connected?(%{bot_token: t}) when is_binary(t) and t != "", do: true
  defp wechat_connected?(_), do: false

  defp nil_if_blank(""), do: nil
  defp nil_if_blank(v), do: v

  # Language options for the locale dropdowns, from the Copy catalog.
  defp locale_options, do: Enum.map(Long.Copy.locales(), &{&1, locale_label(&1)})

  # Every IANA zone for the datalist, common ones first so they surface near
  # the top as the user types.
  defp timezone_options do
    common =
      ~w(Asia/Shanghai Asia/Hong_Kong Asia/Tokyo Asia/Singapore Asia/Kolkata
         Europe/London Europe/Paris America/New_York America/Los_Angeles UTC)

    (common ++ Tzdata.zone_list()) |> Enum.uniq()
  end

  defp locale_label("en"), do: "English"
  defp locale_label("zh"), do: "中文"
  defp locale_label(code), do: code

  # Disabled / never-scheduled rows have `next_run_at = nil`; map them
  # to a sentinel far in the future so they sort to the bottom instead
  # of crashing DateTime.compare/2 with a no-clause match.
  defp sort_key_next_run(%{next_run_at: nil}), do: ~U[9999-12-31 23:59:59Z]
  defp sort_key_next_run(%{next_run_at: dt}), do: dt

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

  # ── Events: Groups ───────────────────────────────────────────────────

  def handle_event("new_group", %{"group" => %{"name" => name}}, socket) do
    case Agent.create_group(%{name: name}) do
      {:ok, _} -> {:noreply, socket |> load_section(:groups) |> put_flash(:info, "Group created.")}
      {:error, e} -> {:noreply, put_flash(socket, :error, "Create failed: #{inspect(e)}")}
    end
  end

  def handle_event("destroy_group", %{"id" => id}, socket) do
    with {:ok, hh} <- Agent.get_group(id), :ok <- Agent.destroy_group(hh) do
      {:noreply, load_section(socket, :groups)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Delete failed.")}
    end
  end

  def handle_event("new_member", %{"member" => params}, socket) do
    attrs = %{
      group_id: params["group_id"],
      display_name: params["display_name"],
      relation: params["relation"],
      role: params["role"]
    }

    case Agent.create_member(attrs) do
      {:ok, _} -> {:noreply, load_section(socket, :groups)}
      {:error, e} -> {:noreply, put_flash(socket, :error, "Add member failed: #{inspect(e)}")}
    end
  end

  def handle_event("destroy_member", %{"id" => id}, socket) do
    with {:ok, m} <- Agent.get_member(id), :ok <- Agent.destroy_member(m) do
      {:noreply, load_section(socket, :groups)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Delete failed.")}
    end
  end

  def handle_event("regenerate_bind_code", %{"id" => id}, socket) do
    with {:ok, m} <- Agent.get_member(id), {:ok, _} <- Agent.regenerate_member_bind_code(m) do
      {:noreply, socket |> load_section(:groups) |> put_flash(:info, "Bind code regenerated.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Operation failed.")}
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
      scope: safe_atom(params["scope"], :general, memory_scopes()),
      key: String.trim(params["key"] || ""),
      value: params["value"] || "",
      kind: safe_atom(params["kind"], :fact, memory_kinds()),
      importance: parse_int(params["importance"], 3)
    }

    case Agent.put_global_memory(attrs) do
      {:ok, _} -> {:noreply, socket |> assign(:editing, nil) |> load_section(:memories)}
      {:error, e} -> {:noreply, put_flash(socket, :error, "Save failed: #{inspect(e)}")}
    end
  end

  def handle_event("edit_session_memory", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.session_memories, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      row ->
        editing = %{
          __action__: :edit_session,
          id: row.id,
          session_id: row.session_id,
          key: row.key,
          value: row.value,
          kind: to_string(row.kind || :fact),
          importance: row.importance || 3
        }

        {:noreply, assign(socket, :editing, editing)}
    end
  end

  def handle_event("save_session_memory", %{"memory" => params}, socket) do
    # Upsert keyed on (session_id, key) — same session + key updates in place.
    attrs = %{
      session_id: params["session_id"],
      key: String.trim(params["key"] || ""),
      value: params["value"] || "",
      kind: safe_atom(params["kind"], :fact, memory_kinds()),
      importance: parse_int(params["importance"], 3)
    }

    case Agent.put_session_memory(attrs) do
      {:ok, _} -> {:noreply, socket |> assign(:editing, nil) |> load_section(:memories)}
      {:error, e} -> {:noreply, put_flash(socket, :error, "Save failed: #{inspect(e)}")}
    end
  end

  # ── Events: Skills ───────────────────────────────────────────────────

  def handle_event("save_phrase", %{"key" => key, "locale" => locale, "text" => text}, socket) do
    text = String.trim(text)

    outcome =
      if text == "",
        do: clear_phrase_override(key, locale),
        else: Agent.upsert_phrase(%{key: key, locale: locale, text: text})

    case outcome do
      {:ok, _} ->
        Long.Copy.reload()
        {:noreply, socket |> load_section(:phrases) |> put_flash(:info, "Phrase saved.")}

      :ok ->
        Long.Copy.reload()
        {:noreply, socket |> load_section(:phrases) |> put_flash(:info, "Override cleared.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Save failed.")}
    end
  end

  def handle_event("skill_reindex", _, socket) do
    :ok = SkillStore.reindex()
    {:noreply, load_section(socket, :skills) |> put_flash(:info, "Rescanned skill_root.")}
  end

  def handle_event("view_skill", %{"name" => name}, socket) do
    case SkillStore.get(name) do
      {:ok, skill} -> {:noreply, assign(socket, :editing, Map.put(skill, :__action__, :view_skill))}
      _ -> {:noreply, put_flash(socket, :error, "Skill not found — try Reindex.")}
    end
  end

  def handle_event("new_shared_skill", %{"skill" => p}, socket) do
    # No member_id → the shared (global) space.
    case SkillStore.create_skill(p["name"], p["description"], p["body"] || "") do
      {:ok, _dir} ->
        {:noreply, socket |> load_section(:skills) |> put_flash(:info, "Created shared skill “#{p["name"]}”.")}

      {:error, :name_taken} ->
        {:noreply, put_flash(socket, :error, "A skill named “#{p["name"]}” already exists.")}

      {:error, reason} when reason in [:name_required, :description_required] ->
        {:noreply, put_flash(socket, :error, "Name and description are required.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  def handle_event("promote_skill", %{"name" => name}, socket) do
    case SkillStore.promote_to_global(name) do
      :ok ->
        {:noreply, socket |> load_section(:skills) |> put_flash(:info, "Promoted \"#{name}\" to a global skill.")}

      {:error, :name_taken} ->
        {:noreply, put_flash(socket, :error, "A global skill named \"#{name}\" already exists — rename it first.")}

      {:error, :already_global} ->
        {:noreply, put_flash(socket, :error, "\"#{name}\" is already a global skill.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Promote failed: #{inspect(reason)}")}
    end
  end

  # ── Events: Sessions ─────────────────────────────────────────────────

  def handle_event("archive_session", %{"id" => id}, socket) do
    case Agent.archive_session(id) do
      {:ok, _} -> {:noreply, load_section(socket, :sessions)}
      {:error, e} -> {:noreply, put_flash(socket, :error, "Archive failed: #{inspect(e)}")}
    end
  end

  def handle_event("destroy_session", %{"id" => id}, socket) do
    with {:ok, sess} <- Agent.get_session(id),
         :ok <- Agent.destroy_session(sess) do
      {:noreply, load_section(socket, :sessions)}
    else
      {:ok, _} -> {:noreply, load_section(socket, :sessions)}
      {:error, e} -> {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(e)}")}
    end
  end

  # ── Events: Search providers ─────────────────────────────────────────

  def handle_event("new_search", _params, socket) do
    blank = %{
      __action__: :create_search,
      alias: "",
      provider: "tavily",
      api_key: "",
      api_key_env_var: "",
      enabled: true,
      sort_order: 0
    }

    {:noreply, assign(socket, :editing, blank)}
  end

  def handle_event("edit_search", %{"alias" => name}, socket) do
    case Agent.get_search_config(name) do
      {:ok, row} ->
        editing = %{
          __action__: :edit_search,
          alias: row.alias,
          provider: to_string(row.provider),
          api_key: row.api_key || "",
          api_key_env_var: row.api_key_env_var || "",
          enabled: row.enabled,
          sort_order: row.sort_order
        }

        {:noreply, assign(socket, :editing, editing)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("save_search", %{"search" => params}, socket) do
    attrs = %{
      alias: String.trim(params["alias"] || ""),
      provider: safe_atom(params["provider"], :tavily, SearchConfig.providers()),
      api_key: trim_or_nil(params["api_key"]),
      api_key_env_var: trim_or_nil(params["api_key_env_var"]),
      enabled: params["enabled"] == "true",
      sort_order: parse_int(params["sort_order"], 0)
    }

    case Agent.register_search_config(attrs) do
      {:ok, _} -> {:noreply, socket |> assign(:editing, nil) |> load_section(:search)}
      {:error, e} -> {:noreply, put_flash(socket, :error, "Save failed: #{inspect(e)}")}
    end
  end

  def handle_event("toggle_search_enabled", %{"alias" => name}, socket) do
    with {:ok, row} <- Agent.get_search_config(name),
         {:ok, _} <- Agent.update_search_config(row, %{enabled: !row.enabled}) do
      {:noreply, load_section(socket, :search)}
    else
      {:error, e} -> {:noreply, put_flash(socket, :error, "Toggle failed: #{inspect(e)}")}
    end
  end

  def handle_event("destroy_search", %{"alias" => name}, socket) do
    with {:ok, row} <- Agent.get_search_config(name),
         :ok <- Agent.destroy_search_config(row) do
      {:noreply, load_section(socket, :search)}
    else
      {:ok, _} -> {:noreply, load_section(socket, :search)}
      {:error, e} -> {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(e)}")}
    end
  end

  # ── Events: Credentials ──────────────────────────────────────────────

  def handle_event("destroy_bot_user", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.bot_users, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      row ->
        case Agent.destroy_bot_user(row) do
          :ok -> {:noreply, load_section(socket, :credentials)}
          {:ok, _} -> {:noreply, load_section(socket, :credentials)}
          {:error, e} -> {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(e)}")}
        end
    end
  end

  # ── Events: WeChat (QR login modal) ──────────────────────────────────

  def handle_event("open_wechat_login", params, socket) do
    name = params["name"] || "default"
    {:noreply, socket |> assign(:wechat_login_name, name) |> assign(:wechat_modal_open?, true)}
  end

  # Re-sync the table on close so a freshly-scanned account shows up.
  def handle_event("close_wechat_login", _params, socket),
    do: {:noreply, socket |> assign(:wechat_modal_open?, false) |> load_section(:credentials)}

  def handle_event("add_wechat_account", %{"name" => name}, socket) do
    case Agent.upsert_wechat_credential(%{name: String.trim(name)}) do
      {:ok, _} ->
        Long.Agent.Bots.Wechat.Manager.reconcile()

        {:noreply,
         socket
         |> assign(:wechat_login_name, String.trim(name))
         |> assign(:wechat_modal_open?, true)
         |> load_section(:credentials)}

      {:error, e} ->
        {:noreply, put_flash(socket, :error, "Could not add account: #{inspect(e)}")}
    end
  end

  def handle_event("assign_wechat_member", %{"credential_name" => name, "member_id" => mid}, socket) do
    member_id = if mid == "", do: nil, else: mid

    with {:ok, row} <- Agent.get_wechat_credential(name),
         {:ok, _} <- Agent.set_wechat_credential_member(row, %{member_id: member_id}) do
      # Reconcile so the running worker reloads its member binding live.
      Long.Agent.Bots.Wechat.Manager.reconcile()
      {:noreply, socket |> load_section(:credentials) |> put_flash(:info, "Account ↔ member updated.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not update member assignment.")}
    end
  end

  def handle_event("destroy_wechat_credential", params, socket) do
    :ok = Long.Agent.Bots.Wechat.Credential.delete(params["name"] || "default")
    {:noreply, load_section(socket, :credentials)}
  end

  # ── Events: Telegram credentials ─────────────────────────────────────

  def handle_event("new_telegram_credential", _params, socket) do
    blank = %{
      __action__: :create_telegram,
      name: "default",
      bot_token: "",
      username: "",
      enabled: true
    }

    {:noreply, assign(socket, :editing, blank)}
  end

  def handle_event("edit_telegram_credential", %{"name" => name}, socket) do
    case Agent.get_telegram_credential(name) do
      {:ok, row} ->
        editing = %{
          __action__: :edit_telegram,
          id: row.id,
          name: row.name,
          bot_token: row.bot_token,
          username: row.username || "",
          enabled: row.enabled
        }

        {:noreply, assign(socket, :editing, editing)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("save_telegram_credential", %{"telegram" => params}, socket) do
    attrs = %{
      name: trim_or_nil(params["name"]) || "default",
      bot_token: String.trim(params["bot_token"] || ""),
      username: trim_or_nil(params["username"]),
      enabled: params["enabled"] == "true"
    }

    case Agent.upsert_telegram_credential(attrs) do
      {:ok, _row} ->
        Long.Agent.Bots.Telegram.Manager.reconcile()
        {:noreply, socket |> assign(:editing, nil) |> load_section(:credentials)}

      {:error, e} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(e)}")}
    end
  end

  def handle_event("assign_telegram_member", %{"credential_name" => name, "member_id" => mid}, socket) do
    member_id = if mid == "", do: nil, else: mid

    with {:ok, row} <- Agent.get_telegram_credential(name),
         {:ok, _} <- Agent.set_telegram_credential_member(row, %{member_id: member_id}) do
      # Reconcile so the running worker reloads its member binding live.
      Long.Agent.Bots.Telegram.Manager.reconcile()
      {:noreply, socket |> load_section(:credentials) |> put_flash(:info, "Bot ↔ member updated.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not update member assignment.")}
    end
  end

  # ── Events: language (credential / member / group locale) ─────────

  def handle_event("set_wechat_locale", %{"credential_name" => name, "locale" => locale}, socket) do
    with {:ok, row} <- Agent.get_wechat_credential(name),
         {:ok, _} <- Agent.set_wechat_credential_locale(row, %{locale: nil_if_blank(locale)}) do
      {:noreply, socket |> load_section(:credentials) |> put_flash(:info, "Channel language updated.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not update language.")}
    end
  end

  def handle_event("set_telegram_locale", %{"credential_name" => name, "locale" => locale}, socket) do
    with {:ok, row} <- Agent.get_telegram_credential(name),
         {:ok, _} <- Agent.set_telegram_credential_locale(row, %{locale: nil_if_blank(locale)}) do
      {:noreply, socket |> load_section(:credentials) |> put_flash(:info, "Channel language updated.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not update language.")}
    end
  end

  def handle_event("set_group_locale", %{"group_id" => id, "locale" => locale}, socket) do
    with {:ok, hh} <- Agent.get_group(id),
         {:ok, _} <- Agent.update_group(hh, %{locale: nil_if_blank(locale)}) do
      {:noreply, socket |> load_section(:groups) |> put_flash(:info, "Group language updated.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not update language.")}
    end
  end

  def handle_event("set_member_locale", %{"member_id" => id, "locale" => locale}, socket) do
    with {:ok, m} <- Agent.get_member(id),
         {:ok, _} <- Agent.update_member(m, %{locale: nil_if_blank(locale)}) do
      {:noreply, socket |> load_section(:groups) |> put_flash(:info, "Member language updated.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not update language.")}
    end
  end

  def handle_event("set_default_locale", %{"locale" => locale}, socket) do
    Long.Copy.put_default_locale(nil_if_blank(locale))
    {:noreply, socket |> load_section(:groups) |> put_flash(:info, "System default language updated.")}
  end

  def handle_event("set_timezone", %{"timezone" => tz}, socket) do
    # phx-change fires while typing; put_user_timezone ignores half-typed input.
    case Agent.put_user_timezone(tz) do
      :ok -> {:noreply, socket |> load_section(:groups) |> put_flash(:info, "System timezone updated.")}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("toggle_telegram_enabled", %{"name" => name}, socket) do
    with {:ok, row} <- Agent.get_telegram_credential(name),
         {:ok, _} <- Agent.update_telegram_credential(row, %{enabled: !row.enabled}) do
      Long.Agent.Bots.Telegram.Manager.reconcile()
      {:noreply, load_section(socket, :credentials)}
    else
      {:error, e} -> {:noreply, put_flash(socket, :error, "Toggle failed: #{inspect(e)}")}
    end
  end

  def handle_event("destroy_telegram_credential", %{"name" => name}, socket) do
    with {:ok, row} <- Agent.get_telegram_credential(name),
         :ok <- Agent.destroy_telegram_credential(row) do
      Long.Agent.Bots.Telegram.Manager.reconcile()
      {:noreply, load_section(socket, :credentials)}
    else
      {:ok, _} ->
        Long.Agent.Bots.Telegram.Manager.reconcile()
        {:noreply, load_section(socket, :credentials)}

      {:error, e} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(e)}")}
    end
  end

  # ── Events: Scheduled tasks ──────────────────────────────────────────

  def handle_event("new_scheduled", _params, socket) do
    blank = %{
      __action__: :create_scheduled,
      name: "",
      prompt: "",
      repeat: "daily",
      schedule_time: "00:00",
      every_n: 1,
      max_delay_hours: 6,
      enabled: true,
      session_id: ""
    }

    {:noreply, assign(socket, :editing, blank)}
  end

  def handle_event("edit_scheduled", %{"id" => id}, socket) do
    case Agent.get_scheduled_task(id) do
      {:ok, row} ->
        editing = %{
          __action__: :edit_scheduled,
          id: row.id,
          name: row.name,
          prompt: row.prompt,
          repeat: to_string(row.repeat),
          schedule_time: row.schedule_time || "00:00",
          every_n: row.every_n || 1,
          max_delay_hours: row.max_delay_hours || 6,
          enabled: row.enabled,
          session_id: row.session_id || ""
        }

        {:noreply, assign(socket, :editing, editing)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("save_scheduled", %{"scheduled" => params}, socket) do
    attrs = %{
      name: String.trim(params["name"] || ""),
      prompt: params["prompt"] || "",
      repeat: safe_atom(params["repeat"], :daily, scheduled_repeats()),
      schedule_time: String.trim(params["schedule_time"] || "00:00"),
      every_n: parse_int(params["every_n"], 1),
      max_delay_hours: parse_int(params["max_delay_hours"], 6),
      enabled: params["enabled"] == "true"
    }

    # ScheduledTask exposes separate `:create` / `:update` actions
    # (unlike LLMConfig / SearchConfig which use upsert), so we have to
    # dispatch by action explicitly. `session_id` is `:create`-only —
    # the `:update` action rejects it (NoSuchInput).
    result =
      case socket.assigns.editing do
        %{__action__: :edit_scheduled, id: id} ->
          with {:ok, row} <- Agent.get_scheduled_task(id),
               do: Agent.update_scheduled_task(row, attrs)

        _ ->
          Agent.create_scheduled_task(
            Map.put(attrs, :session_id, trim_or_nil(params["session_id"]))
          )
      end

    case result do
      {:ok, _} -> {:noreply, socket |> assign(:editing, nil) |> load_section(:scheduled)}
      {:error, e} -> {:noreply, put_flash(socket, :error, "Save failed: #{inspect(e)}")}
    end
  end

  def handle_event("toggle_scheduled_enabled", %{"id" => id}, socket) do
    with {:ok, row} <- Agent.get_scheduled_task(id),
         {:ok, _} <- toggle_scheduled(row) do
      {:noreply, load_section(socket, :scheduled)}
    else
      {:error, e} -> {:noreply, put_flash(socket, :error, "Toggle failed: #{inspect(e)}")}
    end
  end

  def handle_event("destroy_scheduled", %{"id" => id}, socket) do
    with {:ok, row} <- Agent.get_scheduled_task(id),
         :ok <- Agent.destroy_scheduled_task(row) do
      {:noreply, load_section(socket, :scheduled)}
    else
      {:ok, _} -> {:noreply, load_section(socket, :scheduled)}
      {:error, e} -> {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(e)}")}
    end
  end

  # ── Events: Monitors ─────────────────────────────────────────────────

  def handle_event("new_monitor", _params, socket) do
    blank = %{
      __action__: :create_monitor,
      name: "",
      script: "// Print one JSON line: {\"notify\": bool, \"message\": string}\nconsole.log(JSON.stringify({ notify: false }));",
      repeat: "every_n_minutes",
      schedule_time: "00:00",
      every_n: 5,
      max_delay_hours: 6,
      cooldown_minutes: 60,
      secret_name: "",
      enabled: true,
      session_id: "",
      runs: []
    }

    {:noreply, assign(socket, :editing, blank)}
  end

  def handle_event("edit_monitor", %{"id" => id}, socket) do
    case Agent.get_monitor(id) do
      {:ok, row} ->
        editing = %{
          __action__: :edit_monitor,
          id: row.id,
          name: row.name,
          script: row.script || "",
          repeat: to_string(row.repeat),
          schedule_time: row.schedule_time || "00:00",
          every_n: row.every_n || 5,
          max_delay_hours: row.max_delay_hours || 6,
          cooldown_minutes: row.cooldown_minutes || 0,
          secret_name: row.secret_name || "",
          enabled: row.enabled,
          session_id: row.session_id || "",
          last_output: row.last_output || %{},
          runs: recent_monitor_runs(row.id)
        }

        {:noreply, assign(socket, :editing, editing)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("save_monitor", %{"monitor" => params}, socket) do
    attrs = %{
      name: String.trim(params["name"] || ""),
      script: params["script"] || "",
      repeat: safe_atom(params["repeat"], :every_n_minutes, scheduled_repeats()),
      schedule_time: String.trim(params["schedule_time"] || "00:00"),
      every_n: parse_int(params["every_n"], 5),
      max_delay_hours: parse_int(params["max_delay_hours"], 6),
      cooldown_minutes: parse_int(params["cooldown_minutes"], 0),
      secret_name: trim_or_nil(params["secret_name"]),
      enabled: params["enabled"] == "true"
    }

    result =
      case socket.assigns.editing do
        %{__action__: :edit_monitor, id: id} ->
          with {:ok, row} <- Agent.get_monitor(id), do: Agent.update_monitor(row, attrs)

        _ ->
          Agent.create_monitor(Map.put(attrs, :session_id, trim_or_nil(params["session_id"])))
      end

    case result do
      {:ok, _} -> {:noreply, socket |> assign(:editing, nil) |> load_section(:monitors)}
      {:error, e} -> {:noreply, put_flash(socket, :error, "Save failed: #{inspect(e)}")}
    end
  end

  def handle_event("toggle_monitor_enabled", %{"id" => id}, socket) do
    with {:ok, row} <- Agent.get_monitor(id),
         {:ok, _} <- toggle_monitor(row) do
      {:noreply, load_section(socket, :monitors)}
    else
      {:error, e} -> {:noreply, put_flash(socket, :error, "Toggle failed: #{inspect(e)}")}
    end
  end

  def handle_event("destroy_monitor", %{"id" => id}, socket) do
    with {:ok, row} <- Agent.get_monitor(id),
         :ok <- Agent.destroy_monitor(row) do
      {:noreply, load_section(socket, :monitors)}
    else
      {:ok, _} -> {:noreply, load_section(socket, :monitors)}
      {:error, e} -> {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(e)}")}
    end
  end

  def handle_event("run_monitor_now", %{"id" => id}, socket) do
    Oban.insert(Long.Agent.Workers.RunMonitor.new(%{monitor_id: id}))

    {:noreply,
     socket
     |> put_flash(:info, "Monitor queued — refresh in a few seconds to see its result.")
     |> load_section(:monitors)}
  end

  # ── Events: Reflection ───────────────────────────────────────────────

  def handle_event("toggle_reflection", _params, socket) do
    on? = !socket.assigns.reflection_enabled
    _ = Agent.set_reflection_enabled(on?)

    {:noreply,
     socket
     |> assign(:reflection_enabled, on?)
     |> put_flash(:info, if(on?, do: "Silent reflection enabled", else: "Silent reflection disabled"))}
  end

  def handle_event("set_reflection_hour", %{"hour" => hour}, socket) do
    case Integer.parse(hour) do
      {h, _} when h in 0..23 ->
        _ = Agent.set_reflection_hour(h)
        {:noreply, assign(socket, :reflection_hour, h)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_reflection_task", %{"id" => id}, socket) do
    case Agent.get_scheduled_task(id) do
      {:ok, %{enabled: true} = task} ->
        _ = Agent.disable_scheduled_task(task)

      {:ok, task} ->
        next = Long.Agent.Schedule.compute_next_run_at(task, DateTime.utc_now())
        _ = Agent.update_scheduled_task(task, %{enabled: true, next_run_at: next})

      _ ->
        :ok
    end

    {:noreply, assign(socket, :reflection_tasks, Agent.list_reflection_tasks())}
  end

  # Trigger a reflection turn right now, bypassing the schedule + activity
  # gate (it's a manual "run it now"). Silent end-to-end as always.
  def handle_event("run_reflection_now", %{"id" => id}, socket) do
    case Agent.get_scheduled_task(id) do
      {:ok, task} ->
        _ =
          Long.Agent.Server.send_user_message(task.session_id, task.prompt,
            reflection?: true,
            internal: true
          )

        {:noreply, put_flash(socket, :info, "Reflection triggered for this session")}

      _ ->
        {:noreply, put_flash(socket, :error, "Task not found")}
    end
  end

  # ── Events: Secrets ──────────────────────────────────────────────────

  def handle_event("new_secret", _params, socket) do
    {:noreply,
     assign(socket, :editing, %{__action__: :create_secret, name: "", value: "", description: ""})}
  end

  def handle_event("edit_secret", %{"name" => name}, socket) do
    case Agent.get_secret_by_name(name) do
      {:ok, row} ->
        editing = %{
          __action__: :edit_secret,
          id: row.id,
          name: row.name,
          value: row.value,
          description: row.description || ""
        }

        {:noreply, assign(socket, :editing, editing)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("save_secret", %{"secret" => params}, socket) do
    attrs = %{
      name: String.trim(params["name"] || ""),
      value: params["value"] || "",
      description: trim_or_nil(params["description"])
    }

    case Agent.put_secret(attrs) do
      {:ok, _row} ->
        {:noreply, socket |> assign(:editing, nil) |> load_section(:secrets)}

      {:error, e} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(e)}")}
    end
  end

  def handle_event("destroy_secret", %{"name" => name}, socket) do
    with {:ok, row} <- Agent.get_secret_by_name(name),
         :ok <- Agent.destroy_secret(row) do
      {:noreply, load_section(socket, :secrets)}
    else
      {:ok, _} -> {:noreply, load_section(socket, :secrets)}
      {:error, e} -> {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(e)}")}
    end
  end

  # ── PubSub ───────────────────────────────────────────────────────────

  # Embedded WechatLive.Login broadcasts this when a scan confirms;
  # refresh the WeChat card so it flips to "connected" without the
  # operator reopening the page.
  @impl true
  def handle_info(:wechat_connected, socket),
    do: {:noreply, load_section(socket, :credentials)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Template ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-zinc-50 text-zinc-900">
      <aside class="w-60 border-r border-zinc-200 bg-white flex flex-col shrink-0">
        <div class="p-4 border-b border-zinc-100">
          <div class="flex items-center gap-2 font-semibold text-zinc-900">
            <span class="inline-flex h-6 w-6 items-center justify-center rounded-md bg-primary-600 text-xs font-bold text-white">
              L
            </span>
            Long
          </div>
          <.link
            navigate={~p"/"}
            class="mt-2 inline-flex items-center gap-1 text-xs text-zinc-500 hover:text-zinc-800"
          >
            <.icon name="hero-arrow-left" class="size-3.5" /> {gettext("Back to home")}
          </.link>
        </div>
        <nav class="flex-1 overflow-y-auto p-3 space-y-0.5">
          <.link
            :for={{key, _label, icon} <- @sections}
            navigate={section_path(key)}
            class={[
              "flex items-center gap-2.5 rounded-lg px-3 py-2 text-sm font-medium transition-colors",
              if(@section == key,
                do: "bg-primary-50 text-primary-700",
                else: "text-zinc-600 hover:bg-zinc-100 hover:text-zinc-900"
              )
            ]}
          >
            <.icon name={icon} class="size-4 shrink-0" />
            {nav_label(key)}
          </.link>
        </nav>
        <div class="border-t border-zinc-100 p-3">
          <.language_switcher locale={@locale} />
        </div>
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
          scopes={memory_scopes()}
          kinds={memory_kinds()}
        />
        <.session_memory_modal
          :if={editing_kind(@editing) == :session_memory}
          editing={@editing}
          kinds={memory_kinds()}
        />
        <.search_modal
          :if={editing_kind(@editing) == :search}
          editing={@editing}
          providers={search_providers()}
        />
        <.scheduled_modal
          :if={editing_kind(@editing) == :scheduled}
          editing={@editing}
          repeats={scheduled_repeats()}
        />
        <.monitor_modal
          :if={editing_kind(@editing) == :monitor}
          editing={@editing}
          repeats={scheduled_repeats()}
        />
        <.secret_modal :if={editing_kind(@editing) == :secret} editing={@editing} />
        <.telegram_modal :if={editing_kind(@editing) == :telegram} editing={@editing} />
        <.skill_modal :if={editing_kind(@editing) == :skill} editing={@editing} />
        <.wechat_login_modal
          :if={@wechat_modal_open?}
          socket={@socket}
          login_name={@wechat_login_name}
        />
      </main>
    </div>
    """
  end

  defp editing_kind(nil), do: nil
  defp editing_kind(%{__action__: a}) when a in [:create, :edit_llm], do: :llm
  defp editing_kind(%{__action__: :edit_global}), do: :global_memory
  defp editing_kind(%{__action__: :edit_session}), do: :session_memory
  defp editing_kind(%{__action__: a}) when a in [:create_search, :edit_search], do: :search

  defp editing_kind(%{__action__: a}) when a in [:create_scheduled, :edit_scheduled],
    do: :scheduled

  defp editing_kind(%{__action__: a}) when a in [:create_monitor, :edit_monitor],
    do: :monitor

  defp editing_kind(%{__action__: a}) when a in [:create_secret, :edit_secret], do: :secret

  defp editing_kind(%{__action__: a}) when a in [:create_telegram, :edit_telegram],
    do: :telegram

  defp editing_kind(%{__action__: :view_skill}), do: :skill

  defp editing_kind(_), do: nil

  # ── Section views ────────────────────────────────────────────────────

  defp section_view(%{section: :llms} = assigns), do: llm_section(assigns)
  defp section_view(%{section: :groups} = assigns), do: groups_section(assigns)
  defp section_view(%{section: :memories} = assigns), do: memory_section(assigns)
  defp section_view(%{section: :skills} = assigns), do: skill_section(assigns)
  defp section_view(%{section: :sessions} = assigns), do: sessions_section(assigns)
  defp section_view(%{section: :search} = assigns), do: search_section(assigns)
  defp section_view(%{section: :credentials} = assigns), do: credentials_section(assigns)
  defp section_view(%{section: :scheduled} = assigns), do: scheduled_section(assigns)
  defp section_view(%{section: :monitors} = assigns), do: monitors_section(assigns)
  defp section_view(%{section: :reflection} = assigns), do: reflection_section(assigns)
  defp section_view(%{section: :secrets} = assigns), do: secrets_section(assigns)
  defp section_view(%{section: :phrases} = assigns), do: phrases_section(assigns)
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
                      do:
                        "Legacy row — set `provider` and `wire_protocol` via Edit to use the new runtime path.",
                      else: nil
                  }
                >
                  {display_provider(llm)}
                </.badge>
              </td>
              <td class="px-4 py-2 text-xs text-zinc-500">{llm.wire_protocol || "—"}</td>
              <td class="px-4 py-2 text-zinc-600 font-mono text-xs">{llm.model}</td>
              <td class="px-4 py-2">
                <.badge
                  color={if llm.enabled, do: "success", else: "silver"}
                  size="extra_small"
                  rounded="full"
                >
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
        <h2 class="text-sm font-semibold text-zinc-700 uppercase tracking-wide">
          L1 · Working checkpoints
        </h2>
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
                <td class="px-4 py-2 text-xs font-mono text-zinc-500">
                  {row.session.title || row.session.id}
                </td>
                <td class="px-4 py-2 text-zinc-700 whitespace-pre-wrap leading-snug">
                  {row.checkpoint.key_info}
                </td>
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
                <td colspan="3" class="px-4 py-6 text-center text-zinc-400 text-sm">
                  (no checkpoints)
                </td>
              </tr>
            </tbody>
          </table>
        </.card>
      </section>

      <section class="space-y-2">
        <h2 class="text-sm font-semibold text-zinc-700 uppercase tracking-wide">
          L2 · Global memory
        </h2>
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
                <td colspan="6" class="px-4 py-6 text-center text-zinc-400 text-sm">
                  (no global memory)
                </td>
              </tr>
            </tbody>
          </table>
        </.card>
      </section>

      <section class="space-y-2">
        <h2 class="text-sm font-semibold text-zinc-700 uppercase tracking-wide">
          L2 · Session memory
        </h2>
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
                  <div class="flex justify-end gap-1.5">
                    <.button
                      phx-click="edit_session_memory"
                      phx-value-id={row.id}
                      variant="base"
                      color="natural"
                      size="extra_small"
                      icon="hero-pencil-square"
                      rounded="medium"
                      title="Edit / view full"
                    />
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
                  </div>
                </td>
              </tr>
              <tr :if={@session_memories == []}>
                <td colspan="5" class="px-4 py-6 text-center text-zinc-400 text-sm">
                  (no session memory)
                </td>
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

      <.card variant="bordered" color="natural" rounded="large" padding="medium">
        <p class="text-xs text-zinc-500 mb-2">
          Create a <strong>shared skill</strong> — visible to every member of every group
          (the independent shared space, separate from members' personal skills).
        </p>
        <form phx-submit="new_shared_skill" class="space-y-2">
          <div class="flex gap-2">
            <input
              name="skill[name]"
              required
              placeholder="name (e.g. daily-standup)"
              class="flex-1 border border-zinc-300 rounded-md px-2 py-1.5 text-sm font-mono"
            />
            <input
              name="skill[description]"
              required
              placeholder="one-line description"
              class="flex-[2] border border-zinc-300 rounded-md px-2 py-1.5 text-sm"
            />
          </div>
          <textarea
            name="skill[body]"
            rows="3"
            placeholder="SKILL.md instructions (markdown)…"
            class="w-full border border-zinc-300 rounded-md px-2 py-1.5 text-sm font-mono"
          ></textarea>
          <div class="flex justify-end">
            <.button type="submit" color="primary" icon="hero-plus" rounded="medium" size="small">
              Create shared skill
            </.button>
          </div>
        </form>
      </.card>

      <.card variant="bordered" color="natural" rounded="large" padding="none">
        <table class="w-full text-sm">
          <thead class="text-xs uppercase text-zinc-500 bg-zinc-50">
            <tr>
              <th class="text-left px-4 py-2.5">Name</th>
              <th class="text-left px-4 py-2.5">Scope</th>
              <th class="text-left px-4 py-2.5">Description</th>
              <th class="text-left px-4 py-2.5">Tags</th>
              <th class="text-left px-4 py-2.5">Path</th>
              <th class="text-right px-4 py-2.5">Used</th>
              <th class="text-right px-4 py-2.5">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={s <- @skills} class="border-t border-zinc-100">
              <td class="px-4 py-2 font-mono text-zinc-800">{s.name}</td>
              <td class="px-4 py-2"><.skill_scope_badge skill={s} owners={@skill_owner_names} /></td>
              <td class="px-4 py-2 text-zinc-600 leading-snug max-w-md">
                {Text.preview(s.description || "", 120)}
              </td>
              <td class="px-4 py-2">
                <span class="inline-flex gap-1">
                  <.badge :for={t <- s.tags || []} color="silver" size="extra_small" rounded="full">
                    {t}
                  </.badge>
                </span>
              </td>
              <td class="px-4 py-2 text-xs font-mono text-zinc-500">{s.relative_path}</td>
              <td class="px-4 py-2 text-right text-zinc-600">{s.use_count}</td>
              <td class="px-4 py-2">
                <div class="flex justify-end gap-1.5">
                  <.button
                    phx-click="view_skill"
                    phx-value-name={s.name}
                    variant="outline"
                    color="natural"
                    size="extra_small"
                    icon="hero-eye"
                    rounded="medium"
                  >
                    View
                  </.button>
                  <.button
                    :if={s[:scope] == :personal}
                    phx-click="promote_skill"
                    phx-value-name={s.name}
                    variant="outline"
                    color="primary"
                    size="extra_small"
                    icon="hero-arrow-up-on-square"
                    rounded="medium"
                    data-confirm={"把个人技能「#{s.name}」提升为全局?所有成员都能用,目录会移动到全局区。"}
                  >
                    提升为全局
                  </.button>
                </div>
              </td>
            </tr>
            <tr :if={@skills == []}>
              <td colspan="7" class="px-4 py-8 text-center text-zinc-400 text-sm">
                No skills under <code class="text-xs">{SkillStore.root()}</code>. Drop a
                <code class="text-xs">SKILL.md</code>
                in there and hit <strong>Reindex</strong>.
              </td>
            </tr>
          </tbody>
        </table>
      </.card>
    </div>
    """
  end

  attr :skill, :map, required: true
  attr :owners, :map, required: true

  defp skill_scope_badge(assigns) do
    ~H"""
    <%= if @skill[:scope] == :personal do %>
      <.badge color="warning" size="extra_small" rounded="full">
        Personal · {@owners[@skill.owner_member_id] || "unknown"}
      </.badge>
    <% else %>
      <.badge color="success" size="extra_small" rounded="full">Global</.badge>
    <% end %>
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

  defp sessions_section(assigns) do
    ~H"""
    <div class="p-6 space-y-4">
      <h1 class="text-xl font-semibold">Sessions</h1>
      <.card variant="bordered" color="natural" rounded="large" padding="none">
        <table class="w-full text-sm">
          <thead class="text-xs uppercase text-zinc-500 bg-zinc-50">
            <tr>
              <th class="text-left px-4 py-2.5">Title</th>
              <th class="text-left px-4 py-2.5">Status</th>
              <th class="text-left px-4 py-2.5">LLM</th>
              <th class="text-right px-4 py-2.5">Tokens</th>
              <th class="text-left px-4 py-2.5">Created</th>
              <th class="text-right px-4 py-2.5">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={s <- @sessions_rows} class="border-t border-zinc-100">
              <td class="px-4 py-2 font-medium text-zinc-800">
                <.link navigate={~p"/chat/#{s.id}"} class="hover:underline">
                  {s.title || short(s.id)}
                </.link>
              </td>
              <td class="px-4 py-2">
                <.badge color={session_status_color(s.status)} size="extra_small" rounded="full">
                  {s.status}
                </.badge>
              </td>
              <td class="px-4 py-2 text-xs font-mono text-zinc-500">{s.llm_alias || "—"}</td>
              <td class="px-4 py-2 text-right text-zinc-600">{s.token_usage || 0}</td>
              <td class="px-4 py-2 text-xs text-zinc-500">{format_dt(s.inserted_at)}</td>
              <td class="px-4 py-2">
                <div class="flex justify-end gap-1.5">
                  <.button
                    :if={s.status != :archived}
                    phx-click="archive_session"
                    phx-value-id={s.id}
                    variant="base"
                    color="natural"
                    size="extra_small"
                    icon="hero-archive-box-arrow-down"
                    rounded="medium"
                    title="Archive"
                  />
                  <.button
                    phx-click="destroy_session"
                    phx-value-id={s.id}
                    variant="base"
                    color="danger"
                    size="extra_small"
                    icon="hero-trash"
                    rounded="medium"
                    data-confirm={"Delete \"#{s.title || s.id}\" and all its messages?"}
                  />
                </div>
              </td>
            </tr>
            <tr :if={@sessions_rows == []}>
              <td colspan="6" class="px-4 py-8 text-center text-zinc-400 text-sm">(no sessions)</td>
            </tr>
          </tbody>
        </table>
      </.card>
    </div>
    """
  end

  defp search_section(assigns) do
    ~H"""
    <div class="p-6 space-y-4">
      <div class="flex items-center gap-3">
        <h1 class="text-xl font-semibold flex-1">Search providers</h1>
        <.button phx-click="new_search" color="primary" icon="hero-plus" rounded="medium" size="small">
          New provider
        </.button>
      </div>

      <.card variant="bordered" color="natural" rounded="large" padding="none">
        <table class="w-full text-sm">
          <thead class="text-xs uppercase text-zinc-500 bg-zinc-50">
            <tr>
              <th class="text-left px-4 py-2.5">Alias</th>
              <th class="text-left px-4 py-2.5">Provider</th>
              <th class="text-left px-4 py-2.5">Status</th>
              <th class="text-right px-4 py-2.5">Sort</th>
              <th class="text-right px-4 py-2.5">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @search_configs} class="border-t border-zinc-100">
              <td class="px-4 py-2 font-medium">{row.alias}</td>
              <td class="px-4 py-2">
                <.badge color="info" size="extra_small" rounded="full">{row.provider}</.badge>
              </td>
              <td class="px-4 py-2">
                <.badge
                  color={if row.enabled, do: "success", else: "silver"}
                  size="extra_small"
                  rounded="full"
                >
                  {if row.enabled, do: "enabled", else: "disabled"}
                </.badge>
              </td>
              <td class="px-4 py-2 text-right text-xs text-zinc-500">{row.sort_order}</td>
              <td class="px-4 py-2">
                <div class="flex justify-end gap-1.5">
                  <.button
                    phx-click="toggle_search_enabled"
                    phx-value-alias={row.alias}
                    variant="base"
                    color="natural"
                    size="extra_small"
                    icon={if row.enabled, do: "hero-pause", else: "hero-play"}
                    rounded="medium"
                  />
                  <.button
                    phx-click="edit_search"
                    phx-value-alias={row.alias}
                    variant="base"
                    color="natural"
                    size="extra_small"
                    icon="hero-pencil-square"
                    rounded="medium"
                  />
                  <.button
                    phx-click="destroy_search"
                    phx-value-alias={row.alias}
                    variant="base"
                    color="danger"
                    size="extra_small"
                    icon="hero-trash"
                    rounded="medium"
                    data-confirm={"Delete \"#{row.alias}\"?"}
                  />
                </div>
              </td>
            </tr>
            <tr :if={@search_configs == []}>
              <td colspan="5" class="px-4 py-8 text-center text-zinc-400 text-sm">
                No search providers. Click <strong>New provider</strong> to add Tavily or Brave.
              </td>
            </tr>
          </tbody>
        </table>
      </.card>
    </div>
    """
  end

  defp credentials_section(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <h1 class="text-xl font-semibold">Channels</h1>

      <section class="space-y-2">
        <h2 class="text-sm font-semibold text-zinc-700 uppercase tracking-wide">WeChat accounts</h2>
        <p class="text-xs text-zinc-500 max-w-2xl">
          Connect one or more WeChat accounts. Assign each to a group member so every
          message arriving on that account runs as that role.
        </p>

        <.card variant="bordered" color="natural" rounded="large" padding="none">
          <table class="w-full text-sm">
            <thead class="text-xs uppercase text-zinc-500 bg-zinc-50">
              <tr>
                <th class="text-left px-4 py-2">Account</th>
                <th class="text-left px-4 py-2">Status</th>
                <th class="text-left px-4 py-2">Member (role)</th>
                <th class="text-left px-4 py-2">Language</th>
                <th class="text-right px-4 py-2">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={c <- @wechat_credentials} id={"wechat-row-#{c.id}"} class="border-t border-zinc-100">
                <td class="px-4 py-2 font-mono text-zinc-800">{c.name}</td>
                <td class="px-4 py-2">
                  <div class="flex items-center gap-2">
                    <.badge
                      color={if wechat_connected?(c), do: "success", else: "silver"}
                      size="extra_small"
                      rounded="full"
                    >
                      {if wechat_connected?(c), do: "connected", else: "no token"}
                    </.badge>
                    <span :if={c.ilink_bot_id} class="text-xs font-mono text-zinc-400">
                      {c.ilink_bot_id}
                    </span>
                  </div>
                </td>
                <td class="px-4 py-2">
                  <form id={"memsel-assign_wechat_member-#{c.name}"} phx-change="assign_wechat_member">
                    <input type="hidden" name="credential_name" value={c.name} />
                    <select
                      name="member_id"
                      class="border border-zinc-300 rounded-md px-2 py-1.5 text-sm"
                    >
                      <option value="">— unassigned —</option>
                      <option
                        :for={{id, label} <- @member_options}
                        value={id}
                        selected={id == c.member_id}
                      >
                        {label}
                      </option>
                    </select>
                  </form>
                </td>
                <td class="px-4 py-2">
                  <form id={"locsel-set_wechat_locale-#{c.name}"} phx-change="set_wechat_locale">
                    <input type="hidden" name="credential_name" value={c.name} />
                    <select name="locale" class="border border-zinc-300 rounded-md px-2 py-1.5 text-sm">
                      <option value="">— inherit —</option>
                      <option :for={{code, label} <- locale_options()} value={code} selected={code == c.locale}>{label}</option>
                    </select>
                  </form>
                </td>
                <td class="px-4 py-2">
                  <div class="flex justify-end gap-1.5">
                    <.button
                      phx-click="open_wechat_login"
                      phx-value-name={c.name}
                      variant="base"
                      color="primary"
                      size="extra_small"
                      icon="hero-qr-code"
                      rounded="medium"
                    >
                      {if wechat_connected?(c), do: "Re-login", else: "Scan"}
                    </.button>
                    <.button
                      phx-click="destroy_wechat_credential"
                      phx-value-name={c.name}
                      variant="base"
                      color="danger"
                      size="extra_small"
                      icon="hero-trash"
                      rounded="medium"
                      data-confirm={"Delete WeChat account \"#{c.name}\"? You'll need to scan again to reconnect."}
                    />
                  </div>
                </td>
              </tr>
              <tr :if={@wechat_credentials == []}>
                <td colspan="5" class="px-4 py-6 text-center text-zinc-400 text-sm">
                  No WeChat accounts yet — add one below.
                </td>
              </tr>
            </tbody>
          </table>

          <form
            phx-submit="add_wechat_account"
            class="flex items-end gap-2 px-4 py-3 border-t border-zinc-200 bg-zinc-50"
          >
            <label class="flex-1 block">
              <span class="text-xs font-medium text-zinc-600">New account name</span>
              <input
                name="name"
                required
                placeholder="e.g. dad-phone"
                class="mt-1 w-full border border-zinc-300 rounded-md px-2 py-1.5 text-sm"
              />
            </label>
            <.button type="submit" color="primary" icon="hero-plus" rounded="medium" size="small">
              Add &amp; scan
            </.button>
          </form>
        </.card>
      </section>

      <section class="space-y-2">
        <h2 class="text-sm font-semibold text-zinc-700 uppercase tracking-wide">Bot users</h2>
        <.card variant="bordered" color="natural" rounded="large" padding="none">
          <table class="w-full text-sm">
            <thead class="text-xs uppercase text-zinc-500 bg-zinc-50">
              <tr>
                <th class="text-left px-4 py-2.5">Platform</th>
                <th class="text-left px-4 py-2.5">External id</th>
                <th class="text-left px-4 py-2.5">Display</th>
                <th class="text-left px-4 py-2.5">Chat</th>
                <th class="text-right px-4 py-2.5">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={u <- @bot_users} class="border-t border-zinc-100">
                <td class="px-4 py-2">
                  <.badge color="info" size="extra_small" rounded="full">{u.platform}</.badge>
                </td>
                <td class="px-4 py-2 text-xs font-mono text-zinc-700">{u.external_id}</td>
                <td class="px-4 py-2 text-zinc-700">{u.display_name || "—"}</td>
                <td class="px-4 py-2 text-xs font-mono text-zinc-500">{u.chat_id || "—"}</td>
                <td class="px-4 py-2 text-right">
                  <.button
                    phx-click="destroy_bot_user"
                    phx-value-id={u.id}
                    variant="base"
                    color="danger"
                    size="extra_small"
                    icon="hero-trash"
                    rounded="medium"
                    data-confirm={"Delete bot user \"#{u.external_id}\"?"}
                  />
                </td>
              </tr>
              <tr :if={@bot_users == []}>
                <td colspan="5" class="px-4 py-8 text-center text-zinc-400 text-sm">
                  (no bot users)
                </td>
              </tr>
            </tbody>
          </table>
        </.card>
      </section>

      <section class="space-y-2">
        <div class="flex items-center gap-3">
          <h2 class="text-sm font-semibold text-zinc-700 uppercase tracking-wide flex-1">
            Telegram
          </h2>
          <.button
            phx-click="new_telegram_credential"
            color="primary"
            icon="hero-plus"
            rounded="medium"
            size="extra_small"
          >
            New Telegram bot
          </.button>
        </div>
        <.card variant="bordered" color="natural" rounded="large" padding="none">
          <table class="w-full text-sm">
            <thead class="text-xs uppercase text-zinc-500 bg-zinc-50">
              <tr>
                <th class="text-left px-4 py-2.5">Name</th>
                <th class="text-left px-4 py-2.5">Username</th>
                <th class="text-left px-4 py-2.5">Member (role)</th>
                <th class="text-left px-4 py-2.5">Language</th>
                <th class="text-left px-4 py-2.5">Token</th>
                <th class="text-left px-4 py-2.5">Status</th>
                <th class="text-right px-4 py-2.5">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={c <- @telegram_credentials} id={"telegram-row-#{c.id}"} class="border-t border-zinc-100">
                <td class="px-4 py-2 font-medium">{c.name}</td>
                <td class="px-4 py-2 text-xs font-mono text-zinc-500">{c.username || "—"}</td>
                <td class="px-4 py-2">
                  <form id={"memsel-assign_telegram_member-#{c.name}"} phx-change="assign_telegram_member">
                    <input type="hidden" name="credential_name" value={c.name} />
                    <select
                      name="member_id"
                      class="border border-zinc-300 rounded-md px-2 py-1.5 text-sm"
                    >
                      <option value="">— unassigned —</option>
                      <option
                        :for={{id, label} <- @member_options}
                        value={id}
                        selected={id == c.member_id}
                      >
                        {label}
                      </option>
                    </select>
                  </form>
                </td>
                <td class="px-4 py-2">
                  <form id={"locsel-set_telegram_locale-#{c.name}"} phx-change="set_telegram_locale">
                    <input type="hidden" name="credential_name" value={c.name} />
                    <select name="locale" class="border border-zinc-300 rounded-md px-2 py-1.5 text-sm">
                      <option value="">— inherit —</option>
                      <option :for={{code, label} <- locale_options()} value={code} selected={code == c.locale}>{label}</option>
                    </select>
                  </form>
                </td>
                <td class="px-4 py-2 text-xs font-mono text-zinc-500">{mask_secret(c.bot_token)}</td>
                <td class="px-4 py-2">
                  <.badge
                    color={if c.enabled, do: "success", else: "silver"}
                    size="extra_small"
                    rounded="full"
                  >
                    {if c.enabled, do: "enabled", else: "paused"}
                  </.badge>
                </td>
                <td class="px-4 py-2">
                  <div class="flex justify-end gap-1.5">
                    <.button
                      phx-click="toggle_telegram_enabled"
                      phx-value-name={c.name}
                      variant="base"
                      color="natural"
                      size="extra_small"
                      icon={if c.enabled, do: "hero-pause", else: "hero-play"}
                      rounded="medium"
                    />
                    <.button
                      phx-click="edit_telegram_credential"
                      phx-value-name={c.name}
                      variant="base"
                      color="natural"
                      size="extra_small"
                      icon="hero-pencil-square"
                      rounded="medium"
                    />
                    <.button
                      phx-click="destroy_telegram_credential"
                      phx-value-name={c.name}
                      variant="base"
                      color="danger"
                      size="extra_small"
                      icon="hero-trash"
                      rounded="medium"
                      data-confirm={"Delete Telegram credential \"#{c.name}\"?"}
                    />
                  </div>
                </td>
              </tr>
              <tr :if={@telegram_credentials == []}>
                <td colspan="7" class="px-4 py-8 text-center text-zinc-400 text-sm">
                  No Telegram credentials. Click <strong>New Telegram bot</strong>
                  and paste a BotFather token.
                </td>
              </tr>
            </tbody>
          </table>
        </.card>
      </section>
    </div>
    """
  end

  defp scheduled_section(assigns) do
    ~H"""
    <div class="p-6 space-y-4">
      <div class="flex items-center gap-3">
        <h1 class="text-xl font-semibold flex-1">Scheduled tasks</h1>
        <.button
          phx-click="new_scheduled"
          color="primary"
          icon="hero-plus"
          rounded="medium"
          size="small"
        >
          New task
        </.button>
      </div>

      <.card variant="bordered" color="natural" rounded="large" padding="none">
        <table class="w-full text-sm">
          <thead class="text-xs uppercase text-zinc-500 bg-zinc-50">
            <tr>
              <th class="text-left px-4 py-2.5">Name</th>
              <th class="text-left px-4 py-2.5">Repeat</th>
              <th class="text-left px-4 py-2.5">Prompt</th>
              <th class="text-left px-4 py-2.5">Status</th>
              <th class="text-left px-4 py-2.5">Next run</th>
              <th class="text-left px-4 py-2.5">Last run</th>
              <th class="text-right px-4 py-2.5">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={t <- @scheduled_tasks} class="border-t border-zinc-100">
              <td class="px-4 py-2 font-medium">{t.name}</td>
              <td class="px-4 py-2">
                <.badge color="info" size="extra_small" rounded="full">{repeat_label(t)}</.badge>
              </td>
              <td class="px-4 py-2 text-zinc-600 max-w-md">{Text.preview(t.prompt || "", 80)}</td>
              <td class="px-4 py-2">
                <.badge
                  color={if t.enabled, do: "success", else: "silver"}
                  size="extra_small"
                  rounded="full"
                >
                  {if t.enabled, do: "on", else: "off"}
                </.badge>
              </td>
              <td class="px-4 py-2 text-xs text-zinc-500">{format_dt(t.next_run_at)}</td>
              <td class="px-4 py-2 text-xs text-zinc-500">{format_dt(t.last_run_at)}</td>
              <td class="px-4 py-2">
                <div class="flex justify-end gap-1.5">
                  <.button
                    phx-click="toggle_scheduled_enabled"
                    phx-value-id={t.id}
                    variant="base"
                    color="natural"
                    size="extra_small"
                    icon={if t.enabled, do: "hero-pause", else: "hero-play"}
                    rounded="medium"
                  />
                  <.button
                    phx-click="edit_scheduled"
                    phx-value-id={t.id}
                    variant="base"
                    color="natural"
                    size="extra_small"
                    icon="hero-pencil-square"
                    rounded="medium"
                  />
                  <.button
                    phx-click="destroy_scheduled"
                    phx-value-id={t.id}
                    variant="base"
                    color="danger"
                    size="extra_small"
                    icon="hero-trash"
                    rounded="medium"
                    data-confirm={"Delete \"#{t.name}\"?"}
                  />
                </div>
              </td>
            </tr>
            <tr :if={@scheduled_tasks == []}>
              <td colspan="7" class="px-4 py-8 text-center text-zinc-400 text-sm">
                No scheduled tasks. Click <strong>New task</strong>
                to add one (or let the agent schedule them via GraphQL <code>createScheduledTask</code>).
              </td>
            </tr>
          </tbody>
        </table>
      </.card>
    </div>
    """
  end

  defp monitors_section(assigns) do
    ~H"""
    <div class="p-6 space-y-4">
      <div class="flex items-center gap-3">
        <h1 class="text-xl font-semibold flex-1">{gettext("Monitors")}</h1>
        <p class="text-xs text-zinc-500 max-w-sm">
          {gettext("Scripts that run on an interval and notify only when there's something. ⚡ runs one now.")}
        </p>
        <Button.button phx-click="new_monitor" color="primary" icon="hero-plus" radius="md" size="sm">
          {gettext("New monitor")}
        </Button.button>
      </div>

      <div class="rounded-lg border border-zinc-200 bg-white overflow-hidden">
        <table class="w-full text-sm">
          <thead class="text-xs uppercase text-zinc-500 bg-zinc-50">
            <tr>
              <th class="text-left px-4 py-2.5">{gettext("Name")}</th>
              <th class="text-left px-4 py-2.5">{gettext("Every")}</th>
              <th class="text-left px-4 py-2.5">{gettext("On")}</th>
              <th class="text-left px-4 py-2.5">{gettext("Last status")}</th>
              <th class="text-left px-4 py-2.5">{gettext("Next run")}</th>
              <th class="text-left px-4 py-2.5">{gettext("Last run")}</th>
              <th class="text-right px-4 py-2.5">{gettext("Actions")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={m <- @monitors} class="border-t border-zinc-100">
              <td class="px-4 py-2 font-medium">{m.name}</td>
              <td class="px-4 py-2">
                <Badge.badge color="info" size="xs">{repeat_label(m)}</Badge.badge>
              </td>
              <td class="px-4 py-2">
                <Badge.badge color={if m.enabled, do: "success", else: "gray"} size="xs">
                  {if m.enabled, do: gettext("on"), else: gettext("off")}
                </Badge.badge>
              </td>
              <td class="px-4 py-2">
                <Badge.badge color={monitor_status_color(m.last_status)} size="xs">
                  {m.last_status || "—"}
                </Badge.badge>
              </td>
              <td class="px-4 py-2 text-xs text-zinc-500">{format_dt(m.next_run_at)}</td>
              <td class="px-4 py-2 text-xs text-zinc-500">{format_dt(m.last_run_at)}</td>
              <td class="px-4 py-2">
                <div class="flex justify-end gap-1">
                  <Button.icon_button
                    phx-click="run_monitor_now"
                    phx-value-id={m.id}
                    color="gray"
                    size="xs"
                    title={gettext("Run now")}
                  >
                    <.icon name="hero-bolt" class="size-4" />
                  </Button.icon_button>
                  <Button.icon_button
                    phx-click="toggle_monitor_enabled"
                    phx-value-id={m.id}
                    color="gray"
                    size="xs"
                    title={if m.enabled, do: gettext("Disable"), else: gettext("Enable")}
                  >
                    <.icon name={if m.enabled, do: "hero-pause", else: "hero-play"} class="size-4" />
                  </Button.icon_button>
                  <Button.icon_button
                    phx-click="edit_monitor"
                    phx-value-id={m.id}
                    color="gray"
                    size="xs"
                    title={gettext("Edit")}
                  >
                    <.icon name="hero-pencil-square" class="size-4" />
                  </Button.icon_button>
                  <Button.icon_button
                    phx-click="destroy_monitor"
                    phx-value-id={m.id}
                    color="danger"
                    size="xs"
                    data-confirm={gettext("Delete \"%{name}\"?", name: m.name)}
                    title={gettext("Delete")}
                  >
                    <.icon name="hero-trash" class="size-4" />
                  </Button.icon_button>
                </div>
              </td>
            </tr>
            <tr :if={@monitors == []}>
              <td colspan="7" class="px-4 py-8 text-center text-zinc-400 text-sm">
                {gettext("No monitors yet. Click \"New monitor\", or let the agent create one.")}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp monitor_status_color("notified"), do: "success"
  defp monitor_status_color("silent"), do: "gray"
  defp monitor_status_color("error"), do: "danger"
  defp monitor_status_color(_), do: "info"

  attr :editing, :map, required: true
  attr :repeats, :list, required: true

  defp monitor_modal(assigns) do
    assigns = assign(assigns, :is_new?, assigns.editing.__action__ == :create_monitor)

    ~H"""
    <.modal
      id="monitor-edit-modal"
      show
      title={if @is_new?, do: "New monitor", else: "Edit #{@editing.name}"}
      on_cancel={JS.push("cancel_edit")}
      size="large"
    >
      <form phx-submit="save_monitor" class="space-y-3">
        <div class="grid grid-cols-2 gap-3">
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Name</span>
            <input
              name="monitor[name]"
              value={@editing.name}
              required
              readonly={!@is_new?}
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm font-mono"
              placeholder="e.g. xiaomi_stock_watch"
            />
          </label>
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Repeat</span>
            <select
              name="monitor[repeat]"
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm"
            >
              <option :for={r <- @repeats} value={r} selected={@editing.repeat == r}>{r}</option>
            </select>
          </label>
        </div>

        <label class="block">
          <span class="text-xs font-medium text-zinc-600">
            Script — Deno/TS. Print one JSON line as the last stdout line:
            notify (bool), message (string), optional key.
          </span>
          <textarea
            name="monitor[script]"
            rows="12"
            required
            class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-xs font-mono leading-snug"
          >{@editing.script}</textarea>
        </label>

        <div class="grid grid-cols-4 gap-3">
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Every N</span>
            <input
              type="number"
              min="1"
              name="monitor[every_n]"
              value={@editing.every_n}
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm"
            />
          </label>
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Time (UTC)</span>
            <input
              name="monitor[schedule_time]"
              value={@editing.schedule_time}
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm font-mono"
              placeholder="08:00"
            />
          </label>
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Cooldown (min)</span>
            <input
              type="number"
              min="0"
              name="monitor[cooldown_minutes]"
              value={@editing.cooldown_minutes}
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm"
            />
          </label>
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Max delay (h)</span>
            <input
              type="number"
              min="0"
              name="monitor[max_delay_hours]"
              value={@editing.max_delay_hours}
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm"
            />
          </label>
        </div>

        <div class="grid grid-cols-2 gap-3">
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Secret name (optional → SECRET env)</span>
            <input
              name="monitor[secret_name]"
              value={@editing.secret_name}
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm font-mono"
            />
          </label>
          <label :if={@is_new?} class="block">
            <span class="text-xs font-medium text-zinc-600">Session id (where to notify)</span>
            <input
              name="monitor[session_id]"
              value={@editing.session_id}
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm font-mono"
              placeholder="UUID"
            />
          </label>
        </div>

        <div
          :if={!@is_new? and map_size(@editing.last_output) > 0}
          class="rounded-md bg-zinc-50 border border-zinc-200 p-3"
        >
          <div class="text-xs font-medium text-zinc-600 mb-1">Latest tick</div>
          <pre class="text-xs text-zinc-700 whitespace-pre-wrap break-all max-h-32 overflow-auto">{Jason.encode!(@editing.last_output, pretty: true)}</pre>
        </div>

        <div :if={!@is_new?} class="rounded-md border border-zinc-200">
          <div class="text-xs font-medium text-zinc-600 px-3 py-2 bg-zinc-50 border-b border-zinc-200">
            Recent runs (latest executions — silent / notified / error)
          </div>
          <div class="max-h-56 overflow-auto">
            <table class="w-full text-xs">
              <tbody>
                <tr :for={r <- @editing.runs} class="border-t border-zinc-100 align-top">
                  <td class="px-3 py-1.5 whitespace-nowrap text-zinc-500">{format_dt(r.ran_at)}</td>
                  <td class="px-2 py-1.5">
                    <.badge color={monitor_status_color(r.status)} size="extra_small" rounded="full">
                      {r.status}
                    </.badge>
                  </td>
                  <td class="px-2 py-1.5 text-zinc-600">{r.decision}</td>
                  <td class="px-3 py-1.5 text-zinc-700 break-all">{r.message || Text.preview(r.stdout_tail || "", 80)}</td>
                </tr>
                <tr :if={@editing.runs == []}>
                  <td colspan="4" class="px-3 py-4 text-center text-zinc-400">
                    No notifications or errors recorded yet.
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <label class="flex items-center gap-2 text-sm text-zinc-700 pt-1">
          <input type="checkbox" name="monitor[enabled]" value="true" checked={@editing.enabled} />
          Enabled
        </label>

        <div class="flex justify-end gap-2 pt-2">
          <.button
            type="button"
            phx-click="cancel_edit"
            variant="base"
            color="natural"
            rounded="medium"
            size="small"
          >
            Cancel
          </.button>
          <.button type="submit" color="primary" rounded="medium" size="small">Save</.button>
        </div>
      </form>
    </.modal>
    """
  end

  defp groups_section(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <div class="flex items-center gap-3">
        <h1 class="text-xl font-semibold flex-1">Groups</h1>
      </div>

      <.card variant="bordered" color="natural" rounded="large" padding="none">
        <div class="flex items-center gap-3 p-4">
          <div class="flex-1">
            <div class="text-sm font-medium text-zinc-800">System default language</div>
            <div class="text-xs text-zinc-500">
              The fallback used when a channel, member, or group sets no language of its own.
            </div>
          </div>
          <form id="locsel-set_default_locale-system" phx-change="set_default_locale">
            <input type="hidden" name="scope" value="system" />
            <select name="locale" class="border border-zinc-300 rounded-md px-2 py-1.5 text-sm">
              <option value="">— inherit —</option>
              <option :for={{code, label} <- locale_options()} value={code} selected={code == Long.Copy.default_locale_setting()}>{label}</option>
            </select>
          </form>
        </div>
      </.card>

      <.card variant="bordered" color="natural" rounded="large" padding="none">
        <div class="flex items-center gap-3 p-4">
          <div class="flex-1">
            <div class="text-sm font-medium text-zinc-800">System timezone</div>
            <div class="text-xs text-zinc-500">
              How the agent reads your local time when scheduling reminders
              (e.g. "remind me at 8:30am"). The agent also picks this up when
              you tell it where you are.
            </div>
          </div>
          <% current_tz = Agent.user_timezone() %>
          <form id="tzsel-set_timezone" phx-change="set_timezone">
            <input
              type="text"
              name="timezone"
              list="tz-datalist"
              autocomplete="off"
              phx-debounce="300"
              placeholder={"now: #{current_tz} — type to change"}
              class="border border-zinc-300 rounded-md px-2 py-1.5 text-sm w-72"
            />
            <datalist id="tz-datalist">
              <option :for={tz <- timezone_options()} value={tz}></option>
            </datalist>
          </form>
        </div>
      </.card>

      <div class="rounded-lg border border-blue-200 bg-blue-50 p-4 text-xs text-zinc-600 max-w-3xl leading-relaxed space-y-2">
        <p class="font-medium text-zinc-800">How members link their WeChat / Telegram</p>
        <p>
          <span class="font-medium">Set up once (owner):</span>
          on the <.link navigate={~p"/manage/credentials"} class="text-blue-700 underline">Channels</.link>
          page, scan the WeChat QR to host the group's <em>single</em> WeChat account, and/or add a
          Telegram bot. This is a one-time login — members do <em>not</em> each scan a QR.
        </p>
        <p>Then each member links their own chat to that shared bot:</p>
        <ul class="list-disc list-inside space-y-1">
          <li><span class="font-medium">Telegram</span> — open the bot and send it any message (native multi-user; each Telegram account is separate).</li>
          <li><span class="font-medium">WeChat</span> — add the hosted account as a friend, then DM it. Each contact is recognized separately by their WeChat id.</li>
        </ul>
        <p>
          Finally the member sends <code class="bg-white px-1 rounded">/bind &lt;code&gt;</code>
          (the per-member command below). One member can link both WeChat and Telegram; once bound,
          members can reach each other (e.g. ask the agent to "notify Alex …").
        </p>
      </div>

      <.card variant="bordered" color="natural" rounded="large" padding="none">
        <form phx-submit="new_group" class="flex items-end gap-3 p-4">
          <label class="flex-1 block">
            <span class="text-xs font-medium text-zinc-600">New group</span>
            <input
              name="group[name]"
              required
              placeholder="e.g. My Home"
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm"
            />
          </label>
          <.button type="submit" color="primary" icon="hero-plus" rounded="medium" size="small">
            Create
          </.button>
        </form>
      </.card>

      <.card
        :for={hh <- @groups}
        variant="bordered"
        color="natural"
        rounded="large"
        padding="none"
      >
        <div class="flex items-center gap-2 px-4 py-3 border-b border-zinc-200 bg-zinc-50">
          <.icon name="hero-user-group" class="size-4 text-zinc-500" />
          <span class="font-semibold flex-1">{hh.name}</span>
          <span class="text-xs text-zinc-500">Default language</span>
          <form id={"locsel-set_group_locale-#{hh.id}"} phx-change="set_group_locale">
            <input type="hidden" name="group_id" value={hh.id} />
            <select name="locale" class="border border-zinc-300 rounded-md px-2 py-1.5 text-sm">
              <option value="">— inherit —</option>
              <option :for={{code, label} <- locale_options()} value={code} selected={code == hh.locale}>{label}</option>
            </select>
          </form>
          <.button
            phx-click="destroy_group"
            phx-value-id={hh.id}
            variant="base"
            color="danger"
            size="extra_small"
            icon="hero-trash"
            rounded="medium"
            data-confirm={"Delete group \"#{hh.name}\"? Its members and their bindings are removed too."}
          />
        </div>

        <table class="w-full text-sm">
          <thead class="text-xs uppercase text-zinc-500 bg-white">
            <tr>
              <th class="text-left px-4 py-2">Member</th>
              <th class="text-left px-4 py-2">Relation</th>
              <th class="text-left px-4 py-2">Role</th>
              <th class="text-left px-4 py-2">Language</th>
              <th class="text-left px-4 py-2">Bind command</th>
              <th class="text-left px-4 py-2">Bound accounts</th>
              <th class="text-right px-4 py-2">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={m <- hh.members} id={"member-row-#{m.id}"} class="border-t border-zinc-100">
              <td class="px-4 py-2 text-zinc-800">{m.display_name}</td>
              <td class="px-4 py-2 text-zinc-600">{relation_label(m.relation)}</td>
              <td class="px-4 py-2 text-xs text-zinc-500">{m.role}</td>
              <td class="px-4 py-2">
                <form id={"locsel-set_member_locale-#{m.id}"} phx-change="set_member_locale">
                  <input type="hidden" name="member_id" value={m.id} />
                  <select name="locale" class="border border-zinc-300 rounded-md px-2 py-1.5 text-sm">
                    <option value="">— inherit —</option>
                    <option :for={{code, label} <- locale_options()} value={code} selected={code == m.locale}>{label}</option>
                  </select>
                </form>
              </td>
              <td class="px-4 py-2">
                <div class="flex items-center gap-1.5">
                  <code class="text-xs font-mono bg-zinc-100 px-1.5 py-0.5 rounded">/bind {m.bind_code}</code>
                  <.button
                    phx-click="regenerate_bind_code"
                    phx-value-id={m.id}
                    variant="base"
                    color="natural"
                    size="extra_small"
                    icon="hero-arrow-path"
                    rounded="medium"
                    title="Regenerate bind code"
                  />
                </div>
              </td>
              <td class="px-4 py-2 text-xs">{bound_accounts(m)}</td>
              <td class="px-4 py-2">
                <div class="flex justify-end">
                  <.button
                    phx-click="destroy_member"
                    phx-value-id={m.id}
                    variant="base"
                    color="danger"
                    size="extra_small"
                    icon="hero-trash"
                    rounded="medium"
                    data-confirm={"Delete member \"#{m.display_name}\"?"}
                  />
                </div>
              </td>
            </tr>
            <tr :if={hh.members == []}>
              <td colspan="7" class="px-4 py-6 text-center text-zinc-400 text-sm">
                No members yet — add one below.
              </td>
            </tr>
          </tbody>
        </table>

        <form phx-submit="new_member" class="flex items-end gap-2 px-4 py-3 border-t border-zinc-200 bg-zinc-50">
          <input type="hidden" name="member[group_id]" value={hh.id} />
          <label class="flex-1 block">
            <span class="text-xs font-medium text-zinc-600">Name</span>
            <input
              name="member[display_name]"
              required
              placeholder="e.g. Alex"
              class="mt-1 w-full border border-zinc-300 rounded-md px-2 py-1.5 text-sm"
            />
          </label>
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Relation</span>
            <select name="member[relation]" class="mt-1 border border-zinc-300 rounded-md px-2 py-1.5 text-sm">
              <option :for={r <- member_relations()} value={r}>{relation_label(r)}</option>
            </select>
          </label>
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Role</span>
            <select name="member[role]" class="mt-1 border border-zinc-300 rounded-md px-2 py-1.5 text-sm">
              <option :for={r <- member_roles()} value={r}>{r}</option>
            </select>
          </label>
          <.button type="submit" color="primary" icon="hero-plus" rounded="medium" size="small">
            Add member
          </.button>
        </form>
      </.card>

      <div :if={@groups == []} class="text-center text-zinc-400 text-sm py-8">
        No groups yet — create one above.
      </div>
    </div>
    """
  end

  # Display label for a member's neutral identity tag (self vs. everyone
  # else). Accepts the enum atom or its string form (select round-trips).
  defp relation_label(r) when r in [:self, "self"], do: "Self"
  defp relation_label(_), do: "Member"

  # Comma-joined platforms this member has bound, or a placeholder.
  defp bound_accounts(%{bot_users: bus}) when is_list(bus) and bus != [],
    do: bus |> Enum.map(&to_string(&1.platform)) |> Enum.join(" · ")

  defp bound_accounts(_), do: "Not bound"

  defp phrases_section(assigns) do
    ~H"""
    <div class="p-6 space-y-4">
      <h1 class="text-xl font-semibold">Phrases</h1>
      <p class="text-xs text-zinc-500 max-w-3xl leading-relaxed">
        Central catalog of bot / system copy, per locale. Each phrase has a built-in default;
        set an <strong>override</strong> here to customize the wording.
        <code>%&#123;name&#125;</code>
        placeholders are filled at runtime — keep them. Leave an override blank to fall back to
        the built-in default. (The agent's own replies are written by the LLM in the user's
        language; this controls only the fixed system messages.)
      </p>

      <.card variant="bordered" color="natural" rounded="large" padding="none">
        <table class="w-full text-sm">
          <thead class="text-xs uppercase text-zinc-500 bg-zinc-50">
            <tr>
              <th class="text-left px-4 py-2">Key</th>
              <th class="text-left px-4 py-2">Locale</th>
              <th class="text-left px-4 py-2">Built-in default</th>
              <th class="text-left px-4 py-2">Override</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={r <- @phrase_rows} class="border-t border-zinc-100 align-top">
              <td class="px-4 py-2 font-mono text-xs text-zinc-800">{r.key}</td>
              <td class="px-4 py-2 text-xs">{r.locale}</td>
              <td class="px-4 py-2 text-xs text-zinc-500 max-w-xs whitespace-pre-wrap">{r.builtin}</td>
              <td class="px-4 py-2">
                <form
                  phx-submit="save_phrase"
                  id={"ph-#{String.replace(r.key, ".", "-")}-#{r.locale}"}
                  class="flex items-start gap-1.5"
                >
                  <input type="hidden" name="key" value={r.key} />
                  <input type="hidden" name="locale" value={r.locale} />
                  <textarea
                    name="text"
                    rows="1"
                    placeholder="(uses default)"
                    class="w-64 border border-zinc-300 rounded-md px-2 py-1 text-xs font-mono"
                  >{r.override}</textarea>
                  <.button
                    type="submit"
                    color="primary"
                    size="extra_small"
                    icon="hero-check"
                    rounded="medium"
                  />
                </form>
              </td>
            </tr>
          </tbody>
        </table>
      </.card>
    </div>
    """
  end

  defp reflection_section(assigns) do
    ~H"""
    <div class="p-6 space-y-4">
      <div>
        <h1 class="text-xl font-semibold">Reflection</h1>
        <p class="text-sm text-zinc-500 mt-1 max-w-2xl">
          Silent reflection: off-peak, each session's agent quietly consolidates its own
          memory and never messages anyone. These tasks are system-managed and are kept out
          of the Scheduled list on purpose.
        </p>
      </div>

      <.card variant="bordered" color="natural" rounded="large" padding="none">
        <div class="p-5 space-y-4">
          <div class="flex items-center gap-4">
            <div class="flex-1">
              <div class="font-medium">Silent reflection</div>
              <div class="text-sm text-zinc-500">
                {if @reflection_enabled,
                  do:
                    "On — sessions reflect daily; new ones are auto-enrolled after their first conversation.",
                  else: "Off — no session reflects and none are auto-enrolled."}
              </div>
            </div>
            <.badge
              color={if @reflection_enabled, do: "success", else: "silver"}
              size="extra_small"
              rounded="full"
            >
              {if @reflection_enabled, do: "on", else: "off"}
            </.badge>
            <.button
              phx-click="toggle_reflection"
              variant="base"
              color={if @reflection_enabled, do: "natural", else: "primary"}
              icon={if @reflection_enabled, do: "hero-pause", else: "hero-play"}
              size="small"
              rounded="medium"
            >
              {if @reflection_enabled, do: "Turn off", else: "Turn on"}
            </.button>
          </div>

          <div class="flex items-center gap-3">
            <div class="flex-1">
              <div class="text-sm font-medium text-zinc-800">Off-peak hour (UTC)</div>
              <div class="text-xs text-zinc-500">
                Minute is spread per session to avoid a thundering herd.
              </div>
            </div>
            <form phx-change="set_reflection_hour">
              <.native_select
                id="reflection-hour"
                name="hour"
                color="natural"
                rounded="small"
                size="small"
                disabled={!@reflection_enabled}
              >
                <:option
                  :for={h <- 0..23}
                  value={Integer.to_string(h)}
                  selected={h == @reflection_hour}
                >
                  {String.pad_leading(Integer.to_string(h), 2, "0")}:xx UTC
                </:option>
              </.native_select>
            </form>
          </div>
        </div>
      </.card>

      <.card variant="bordered" color="natural" rounded="large" padding="none">
        <table class="w-full text-sm">
          <thead class="text-xs uppercase text-zinc-500 bg-zinc-50">
            <tr>
              <th class="text-left px-4 py-2.5">Session</th>
              <th class="text-left px-4 py-2.5">At</th>
              <th class="text-left px-4 py-2.5">Next run (UTC)</th>
              <th class="text-left px-4 py-2.5">Status</th>
              <th class="text-right px-4 py-2.5">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={t <- @reflection_tasks} class="border-t border-zinc-100">
              <td class="px-4 py-2 font-mono text-xs">{reflection_session_label(t)}</td>
              <td class="px-4 py-2">{t.schedule_time} UTC</td>
              <td class="px-4 py-2 text-xs text-zinc-500">{reflection_dt(t.next_run_at)}</td>
              <td class="px-4 py-2">
                <.badge
                  color={if t.enabled, do: "success", else: "silver"}
                  size="extra_small"
                  rounded="full"
                >
                  {if t.enabled, do: "enabled", else: "disabled"}
                </.badge>
              </td>
              <td class="px-4 py-2">
                <div class="flex justify-end gap-1.5">
                  <.button
                    phx-click="run_reflection_now"
                    phx-value-id={t.id}
                    variant="base"
                    color="natural"
                    size="extra_small"
                    icon="hero-bolt"
                    rounded="medium"
                    title="Run now"
                  />
                  <.button
                    phx-click="toggle_reflection_task"
                    phx-value-id={t.id}
                    variant="base"
                    color="natural"
                    size="extra_small"
                    icon={if t.enabled, do: "hero-pause", else: "hero-play"}
                    rounded="medium"
                    title={if t.enabled, do: "Disable", else: "Enable"}
                  />
                </div>
              </td>
            </tr>
            <tr :if={@reflection_tasks == []}>
              <td colspan="5" class="px-4 py-8 text-center text-zinc-400 text-sm">
                No reflection tasks yet — one is created automatically after a session's first
                real conversation (when reflection is on).
              </td>
            </tr>
          </tbody>
        </table>
      </.card>
    </div>
    """
  end

  defp reflection_session_label(%{name: "reflection:" <> sid}), do: String.slice(sid, 0, 8)
  defp reflection_session_label(%{name: name}), do: name

  defp reflection_dt(nil), do: "—"
  defp reflection_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp reflection_dt(other), do: to_string(other)

  defp secrets_section(assigns) do
    ~H"""
    <div class="p-6 space-y-4">
      <div class="flex items-center gap-3">
        <h1 class="text-xl font-semibold flex-1">Secrets</h1>
        <.button phx-click="new_secret" color="primary" icon="hero-plus" rounded="medium" size="small">
          New secret
        </.button>
      </div>

      <p class="text-xs text-zinc-500 max-w-2xl leading-relaxed">
        Flat key/value store for tokens the agent needs at tool-call time.
        Stored plaintext (LAN-only) but kept out of memory + chat history.
        The agent reads these via the <code>graphql</code> tool — ask it to
        fetch a secret by name when it needs to authenticate against an API.
      </p>

      <.card variant="bordered" color="natural" rounded="large" padding="none">
        <table class="w-full text-sm">
          <thead class="text-xs uppercase text-zinc-500 bg-zinc-50">
            <tr>
              <th class="text-left px-4 py-2.5">Name</th>
              <th class="text-left px-4 py-2.5">Value</th>
              <th class="text-left px-4 py-2.5">Description</th>
              <th class="text-left px-4 py-2.5">Updated</th>
              <th class="text-right px-4 py-2.5">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={s <- @secrets} class="border-t border-zinc-100">
              <td class="px-4 py-2 font-mono text-zinc-800">{s.name}</td>
              <td class="px-4 py-2 text-xs font-mono text-zinc-500">
                {mask_secret(s.value)}
              </td>
              <td class="px-4 py-2 text-zinc-600 max-w-md">
                {Text.preview(s.description || "", 80)}
              </td>
              <td class="px-4 py-2 text-xs text-zinc-500">{format_dt(s.updated_at)}</td>
              <td class="px-4 py-2">
                <div class="flex justify-end gap-1.5">
                  <.button
                    phx-click="edit_secret"
                    phx-value-name={s.name}
                    variant="base"
                    color="natural"
                    size="extra_small"
                    icon="hero-pencil-square"
                    rounded="medium"
                  />
                  <.button
                    phx-click="destroy_secret"
                    phx-value-name={s.name}
                    variant="base"
                    color="danger"
                    size="extra_small"
                    icon="hero-trash"
                    rounded="medium"
                    data-confirm={"Delete secret \"#{s.name}\"?"}
                  />
                </div>
              </td>
            </tr>
            <tr :if={@secrets == []}>
              <td colspan="5" class="px-4 py-8 text-center text-zinc-400 text-sm">
                No secrets yet. Click <strong>New secret</strong> to add a token.
              </td>
            </tr>
          </tbody>
        </table>
      </.card>
    </div>
    """
  end

  # Show only the head + tail so an operator glancing at the page sees a
  # fingerprint without exposing the full token. Click "edit" to see /
  # change the real value.
  defp mask_secret(nil), do: "—"
  defp mask_secret(""), do: "(empty)"

  defp mask_secret(value) when is_binary(value) do
    len = String.length(value)

    if len <= 8 do
      String.duplicate("•", len)
    else
      String.slice(value, 0, 4) <> "…" <> String.slice(value, -4, 4)
    end
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
              <option :for={w <- @wire_protocols} value={w} selected={@editing.wire_protocol == w}>
                {w}
              </option>
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
          <.button
            type="button"
            phx-click="cancel_edit"
            variant="base"
            color="natural"
            rounded="medium"
            size="small"
          >
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
          <.button
            type="button"
            phx-click="cancel_edit"
            variant="base"
            color="natural"
            rounded="medium"
            size="small"
          >
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

  defp session_memory_modal(assigns) do
    ~H"""
    <.modal
      id="session-memory-edit-modal"
      show
      title={"Edit \"#{@editing.key}\""}
      on_cancel={JS.push("cancel_edit")}
      size="medium"
    >
      <form phx-submit="save_session_memory" class="space-y-3">
        <input type="hidden" name="memory[session_id]" value={@editing.session_id} />
        <div class="grid grid-cols-2 gap-3">
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Kind</span>
            <select
              name="memory[kind]"
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm"
            >
              <option :for={k <- @kinds} value={k} selected={@editing.kind == k}>{k}</option>
            </select>
          </label>
          <label class="block">
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
          <span class="text-xs font-medium text-zinc-600">Value (full)</span>
          <textarea
            name="memory[value]"
            rows="6"
            class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm leading-snug"
          >{@editing.value}</textarea>
        </label>
        <div class="flex justify-end gap-2 pt-2">
          <.button
            type="button"
            phx-click="cancel_edit"
            variant="base"
            color="natural"
            rounded="medium"
            size="small"
          >
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

  # i18n nav labels — literal gettext so they extract. (The @sections English
  # label is the fallback for anything not listed.)
  defp nav_label(:llms), do: gettext("LLMs")
  defp nav_label(:groups), do: gettext("Groups")
  defp nav_label(:memories), do: gettext("Memories")
  defp nav_label(:skills), do: gettext("Skills")
  defp nav_label(:sessions), do: gettext("Sessions")
  defp nav_label(:search), do: gettext("Search")
  defp nav_label(:credentials), do: gettext("Channels")
  defp nav_label(:scheduled), do: gettext("Scheduled")
  defp nav_label(:monitors), do: gettext("Monitors")
  defp nav_label(:reflection), do: gettext("Reflection")
  defp nav_label(:secrets), do: gettext("Secrets")
  defp nav_label(:phrases), do: gettext("Phrases")
  defp nav_label(key), do: to_string(key)

  attr :locale, :string, required: true

  defp language_switcher(assigns) do
    ~H"""
    <div class="flex items-center gap-1 text-xs">
      <.icon name="hero-language" class="size-4 text-zinc-400" />
      <.link
        href={~p"/locale/en"}
        class={["rounded px-1.5 py-0.5", if(@locale == "en", do: "bg-zinc-100 font-semibold text-zinc-900", else: "text-zinc-400 hover:text-zinc-700")]}
      >
        EN
      </.link>
      <.link
        href={~p"/locale/zh"}
        class={["rounded px-1.5 py-0.5", if(@locale == "zh", do: "bg-zinc-100 font-semibold text-zinc-900", else: "text-zinc-400 hover:text-zinc-700")]}
      >
        中文
      </.link>
    </div>
    """
  end

  defp section_path(:llms), do: ~p"/manage/llms"
  defp section_path(:groups), do: ~p"/manage/groups"
  defp section_path(:memories), do: ~p"/manage/memories"
  defp section_path(:skills), do: ~p"/manage/skills"
  defp section_path(:sessions), do: ~p"/manage/sessions"
  defp section_path(:search), do: ~p"/manage/search"
  defp section_path(:credentials), do: ~p"/manage/credentials"
  defp section_path(:scheduled), do: ~p"/manage/scheduled"
  defp section_path(:monitors), do: ~p"/manage/monitors"
  defp section_path(:reflection), do: ~p"/manage/reflection"
  defp section_path(:secrets), do: ~p"/manage/secrets"
  defp section_path(:phrases), do: ~p"/manage/phrases"

  defp section_title(:sessions), do: "Sessions"
  defp section_title(:search), do: "Search providers"
  defp section_title(:credentials), do: "Channels"
  defp section_title(:scheduled), do: "Scheduled tasks"
  defp section_title(:monitors), do: "Monitors"
  defp section_title(:secrets), do: "Secrets"
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

  # Strip empty strings + checkbox booleans, and always derive the legacy
  # `kind` field from `provider` so the `register` upsert satisfies its
  # NOT NULL constraint on both create and edit paths.
  defp sanitize_llm_attrs(params, _action) do
    %{
      alias: String.trim(params["alias"] || ""),
      provider: trim_or_nil(params["provider"]),
      wire_protocol: trim_or_nil(params["wire_protocol"]),
      model: String.trim(params["model"] || ""),
      api_base: trim_or_nil(params["api_base"]),
      api_key: trim_or_nil(params["api_key"]),
      api_key_env_var: trim_or_nil(params["api_key_env_var"]),
      enabled: params["enabled"] == "true",
      default: params["default"] == "true",
      kind: kind_for(trim_or_nil(params["provider"]))
    }
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

  defp toggle_scheduled(%{enabled: true} = row), do: Agent.disable_scheduled_task(row)
  defp toggle_scheduled(row), do: Agent.update_scheduled_task(row, %{enabled: true})

  defp toggle_monitor(%{enabled: true} = row), do: Agent.disable_monitor(row)
  defp toggle_monitor(row), do: Agent.update_monitor(row, %{enabled: true})

  defp recent_monitor_runs(monitor_id) do
    case Agent.list_monitor_runs(monitor_id, page: [limit: 20]) do
      {:ok, %{results: rows}} -> rows
      {:ok, rows} when is_list(rows) -> rows
      _ -> []
    end
  end

  defp session_status_color(:active), do: "success"
  defp session_status_color(:archived), do: "silver"
  defp session_status_color(_), do: "info"

  defp repeat_label(%{repeat: :every_n_hours, every_n: n}), do: "every #{n}h"
  defp repeat_label(%{repeat: :every_n_minutes, every_n: n}), do: "every #{n}m"
  defp repeat_label(%{repeat: r}), do: to_string(r)

  attr :editing, :map, required: true
  attr :providers, :list, required: true

  defp search_modal(assigns) do
    assigns = assign(assigns, :is_new?, assigns.editing.__action__ == :create_search)

    ~H"""
    <.modal
      id="search-edit-modal"
      show
      title={if @is_new?, do: "New search provider", else: "Edit #{@editing.alias}"}
      on_cancel={JS.push("cancel_edit")}
      size="medium"
    >
      <form phx-submit="save_search" class="space-y-3">
        <div class="grid grid-cols-2 gap-3">
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Alias</span>
            <input
              name="search[alias]"
              value={@editing.alias}
              required
              readonly={!@is_new?}
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm font-mono"
              placeholder="e.g. tavily_main"
            />
          </label>
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Provider</span>
            <select
              name="search[provider]"
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm"
            >
              <option :for={p <- @providers} value={p} selected={@editing.provider == p}>{p}</option>
            </select>
          </label>
        </div>

        <div class="grid grid-cols-2 gap-3">
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">API key</span>
            <input
              type="password"
              name="search[api_key]"
              value={@editing.api_key}
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm font-mono"
            />
          </label>
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">…or env var name</span>
            <input
              name="search[api_key_env_var]"
              value={@editing.api_key_env_var}
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm font-mono"
              placeholder="TAVILY_API_KEY"
            />
          </label>
        </div>

        <div class="flex items-center gap-6 pt-1">
          <label class="flex items-center gap-2 text-sm text-zinc-700">
            <input type="checkbox" name="search[enabled]" value="true" checked={@editing.enabled} />
            Enabled
          </label>
          <label class="block w-32">
            <span class="text-xs font-medium text-zinc-600">Sort order</span>
            <input
              type="number"
              name="search[sort_order]"
              value={@editing.sort_order}
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm"
            />
          </label>
        </div>

        <div class="flex justify-end gap-2 pt-2">
          <.button
            type="button"
            phx-click="cancel_edit"
            variant="base"
            color="natural"
            rounded="medium"
            size="small"
          >
            Cancel
          </.button>
          <.button type="submit" color="primary" rounded="medium" size="small">Save</.button>
        </div>
      </form>
    </.modal>
    """
  end

  attr :editing, :map, required: true
  attr :repeats, :list, required: true

  defp scheduled_modal(assigns) do
    assigns = assign(assigns, :is_new?, assigns.editing.__action__ == :create_scheduled)

    ~H"""
    <.modal
      id="scheduled-edit-modal"
      show
      title={if @is_new?, do: "New scheduled task", else: "Edit #{@editing.name}"}
      on_cancel={JS.push("cancel_edit")}
      size="large"
    >
      <form phx-submit="save_scheduled" class="space-y-3">
        <div class="grid grid-cols-2 gap-3">
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Name</span>
            <input
              name="scheduled[name]"
              value={@editing.name}
              required
              readonly={!@is_new?}
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm font-mono"
              placeholder="e.g. morning_hn_digest"
            />
          </label>
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Repeat</span>
            <select
              name="scheduled[repeat]"
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm"
            >
              <option :for={r <- @repeats} value={r} selected={@editing.repeat == r}>{r}</option>
            </select>
          </label>
        </div>

        <label class="block">
          <span class="text-xs font-medium text-zinc-600">Prompt</span>
          <textarea
            name="scheduled[prompt]"
            rows="4"
            required
            class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm leading-snug"
            placeholder="What should the agent do when this fires?"
          >{@editing.prompt}</textarea>
        </label>

        <div class="grid grid-cols-3 gap-3">
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Time (UTC HH:MM)</span>
            <input
              name="scheduled[schedule_time]"
              value={@editing.schedule_time}
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm font-mono"
              placeholder="08:00"
            />
          </label>
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Every N</span>
            <input
              type="number"
              min="1"
              name="scheduled[every_n]"
              value={@editing.every_n}
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm"
            />
          </label>
          <label class="block">
            <span class="text-xs font-medium text-zinc-600">Max delay (h)</span>
            <input
              type="number"
              min="0"
              name="scheduled[max_delay_hours]"
              value={@editing.max_delay_hours}
              class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm"
            />
          </label>
        </div>

        <label class="block">
          <span class="text-xs font-medium text-zinc-600">
            Session id (optional — leave blank to fire into a fresh session)
          </span>
          <input
            name="scheduled[session_id]"
            value={@editing.session_id}
            class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm font-mono"
            placeholder="UUID"
          />
        </label>

        <label class="flex items-center gap-2 text-sm text-zinc-700 pt-1">
          <input type="checkbox" name="scheduled[enabled]" value="true" checked={@editing.enabled} />
          Enabled
        </label>

        <div class="flex justify-end gap-2 pt-2">
          <.button
            type="button"
            phx-click="cancel_edit"
            variant="base"
            color="natural"
            rounded="medium"
            size="small"
          >
            Cancel
          </.button>
          <.button type="submit" color="primary" rounded="medium" size="small">Save</.button>
        </div>
      </form>
    </.modal>
    """
  end

  attr :editing, :map, required: true

  defp secret_modal(assigns) do
    assigns = assign(assigns, :is_new?, assigns.editing.__action__ == :create_secret)

    ~H"""
    <.modal
      id="secret-edit-modal"
      show
      title={if @is_new?, do: "New secret", else: "Edit #{@editing.name}"}
      on_cancel={JS.push("cancel_edit")}
      size="medium"
    >
      <form phx-submit="save_secret" class="space-y-3">
        <label class="block">
          <span class="text-xs font-medium text-zinc-600">Name</span>
          <input
            name="secret[name]"
            value={@editing.name}
            required
            readonly={!@is_new?}
            class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm font-mono"
            placeholder="e.g. github_personal"
          />
          <span class="text-[11px] text-zinc-500">
            Stable identifier the agent passes around. Lowercase + underscores recommended.
          </span>
        </label>

        <label class="block">
          <span class="text-xs font-medium text-zinc-600">Value</span>
          <textarea
            name="secret[value]"
            rows="3"
            required
            class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm font-mono"
            placeholder="Paste the token / key / cookie here"
          >{@editing.value}</textarea>
        </label>

        <label class="block">
          <span class="text-xs font-medium text-zinc-600">Description (optional)</span>
          <input
            name="secret[description]"
            value={@editing.description}
            class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm"
            placeholder="What is this for? Helps the agent pick the right one."
          />
        </label>

        <div class="flex justify-end gap-2 pt-2">
          <.button
            type="button"
            phx-click="cancel_edit"
            variant="base"
            color="natural"
            rounded="medium"
            size="small"
          >
            Cancel
          </.button>
          <.button type="submit" color="primary" rounded="medium" size="small">Save</.button>
        </div>
      </form>
    </.modal>
    """
  end

  attr :editing, :map, required: true

  defp skill_modal(assigns) do
    ~H"""
    <.modal
      id="skill-view-modal"
      show
      title={"Skill · #{@editing.name}"}
      on_cancel={JS.push("cancel_edit")}
      size="large"
    >
      <div class="space-y-4">
        <div class="flex flex-wrap items-center gap-1.5 text-xs">
          <.badge
            color={if @editing.scope == :global, do: "success", else: "info"}
            size="extra_small"
            rounded="full"
          >
            {@editing.scope}
          </.badge>
          <.badge :for={t <- @editing.tags || []} color="silver" size="extra_small" rounded="full">
            {t}
          </.badge>
        </div>

        <p :if={(@editing.description || "") != ""} class="text-sm text-zinc-600 leading-snug">
          {@editing.description}
        </p>

        <div class="text-[11px] text-zinc-500 font-mono space-y-0.5">
          <div>path: {@editing.relative_path}</div>
          <div>dir: {@editing.absolute_path}</div>
        </div>

        <div>
          <div class="text-xs font-medium text-zinc-600 mb-1">SKILL.md</div>
          <pre class="max-h-[60vh] overflow-auto rounded-md border border-zinc-200 bg-zinc-50 p-3 text-xs whitespace-pre-wrap break-words">{if (@editing.body || "") == "", do: "(no SKILL.md body)", else: @editing.body}</pre>
        </div>
      </div>
    </.modal>
    """
  end

  attr :editing, :map, required: true

  defp telegram_modal(assigns) do
    assigns = assign(assigns, :is_new?, assigns.editing.__action__ == :create_telegram)

    ~H"""
    <.modal
      id="telegram-edit-modal"
      show
      title={if @is_new?, do: "New Telegram bot", else: "Edit #{@editing.name}"}
      on_cancel={JS.push("cancel_edit")}
      size="medium"
    >
      <form phx-submit="save_telegram_credential" class="space-y-3">
        <label class="block">
          <span class="text-xs font-medium text-zinc-600">Name</span>
          <input
            name="telegram[name]"
            value={@editing.name}
            required
            readonly={!@is_new?}
            class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm font-mono"
            placeholder="default"
          />
          <span class="text-[11px] text-zinc-500">
            Single-bot deployments leave this as <code>default</code>.
          </span>
        </label>

        <label class="block">
          <span class="text-xs font-medium text-zinc-600">
            Bot token (from <code>@BotFather</code>)
          </span>
          <input
            type="password"
            name="telegram[bot_token]"
            value={@editing.bot_token}
            required
            class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm font-mono"
            placeholder="123456789:ABC-DEF..."
          />
        </label>

        <label class="block">
          <span class="text-xs font-medium text-zinc-600">
            Username (optional, e.g. <code>@my_long_bot</code>)
          </span>
          <input
            name="telegram[username]"
            value={@editing.username}
            class="mt-1 w-full border border-zinc-300 rounded-md px-3 py-2 text-sm font-mono"
            placeholder="my_long_bot"
          />
        </label>

        <label class="flex items-center gap-2 text-sm text-zinc-700 pt-1">
          <input type="checkbox" name="telegram[enabled]" value="true" checked={@editing.enabled} />
          Enabled (worker long-polls Telegram)
        </label>

        <div class="flex justify-end gap-2 pt-2">
          <.button
            type="button"
            phx-click="cancel_edit"
            variant="base"
            color="natural"
            rounded="medium"
            size="small"
          >
            Cancel
          </.button>
          <.button type="submit" color="primary" rounded="medium" size="small">Save</.button>
        </div>
      </form>
    </.modal>
    """
  end

  attr :socket, :any, required: true
  attr :login_name, :string, required: true

  # The QR scan + status polling is a self-contained live flow, so we
  # embed the existing `WechatLive.Login` as a nested LiveView instead
  # of duplicating its logic here. It broadcasts `:wechat_connected` on
  # success, which `handle_info/2` above turns into a section refresh.
  defp wechat_login_modal(assigns) do
    ~H"""
    <.modal
      id="wechat-login-modal"
      show
      title={"WeChat login — #{@login_name}"}
      on_cancel={JS.push("close_wechat_login")}
      size="medium"
    >
      {live_render(@socket, LongWeb.WechatLive.Login,
        id: "wechat-login-embed-#{@login_name}",
        session: %{"embedded" => true, "name" => @login_name}
      )}
    </.modal>
    """
  end
end
