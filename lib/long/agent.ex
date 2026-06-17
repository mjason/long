defmodule Long.Agent do
  @moduledoc """
  Ash domain for the GenericAgent runtime ported into Long.

  Hosts session, message, memory (L1-L4), skill, and LLM-config resources.
  See `~/.claude/projects/-home-mj-dev-elixir-long/memory/project_genericagent_migration.md`
  for migration context.
  """

  use Ash.Domain,
    extensions: [AshAdmin.Domain, AshGraphql.Domain]

  admin do
    show? true
  end

  graphql do
    # Treat the domain as authoritative — let resources declare their
    # own type names and queries/mutations.
    authorize? false
  end

  resources do
    resource Long.Agent.Session do
      define :start_session, action: :start
      define :get_session, action: :read, get_by: [:id]
      define :list_sessions, action: :read
      define :update_session, action: :update
      define :archive_session, action: :archive, get_by: [:id]
      define :destroy_session, action: :destroy
    end

    resource Long.Agent.Message do
      define :list_messages_for_session, action: :by_session, args: [:session_id]
      define :append_message, action: :append
      define :list_messages, action: :read
    end

    resource Long.Agent.WorkingCheckpoint do
      define :upsert_checkpoint, action: :upsert
      define :get_checkpoint, action: :read, get_by: [:session_id]
      define :list_checkpoints, action: :read
    end

    resource Long.Agent.TurnSnapshot do
      define :upsert_turn_snapshot, action: :upsert
      define :get_turn_snapshot, action: :read, get_by: [:session_id]
      define :destroy_turn_snapshot, action: :destroy
    end

    resource Long.Agent.GlobalMemory do
      define :put_global_memory, action: :upsert
      define :list_global_memory, action: :read
      define :delete_global_memory, action: :destroy
      define :bump_global_memory_usage, action: :bump_usage
    end

    resource Long.Agent.Setting do
      define :put_setting, action: :upsert
      define :get_setting, action: :read, get_by: [:key]
      define :delete_setting, action: :destroy
    end

    resource Long.Agent.SessionMemory do
      define :put_session_memory, action: :upsert
      define :list_session_memory, action: :read
      define :list_session_memory_for, action: :by_session, args: [:session_id]
      define :bump_session_memory_usage, action: :bump_usage
      define :delete_session_memory, action: :destroy
    end

    resource Long.Agent.SessionArchive do
      define :archive_payload, action: :create
      define :list_archives, action: :read
    end

    resource Long.Agent.LLMConfig do
      define :register_llm, action: :register
      define :list_llms, action: :read
      define :get_llm, action: :read, get_by: [:alias]
      define :update_llm, action: :update
      define :set_default_llm, action: :set_default, get_by: [:alias]
      define :destroy_llm, action: :destroy
    end

    resource Long.Agent.SearchConfig do
      define :register_search_config, action: :register
      define :list_search_configs, action: :read
      define :get_search_config, action: :read, get_by: [:alias]
      define :update_search_config, action: :update
      define :destroy_search_config, action: :destroy
    end

    resource Long.Agent.ScheduledTask do
      define :create_scheduled_task, action: :create
      define :list_scheduled_tasks, action: :read
      define :list_scheduled_tasks_for_session, action: :by_session, args: [:session_id]
      define :get_scheduled_task, action: :read, get_by: [:id]
      define :get_scheduled_task_by_name, action: :read, get_by: [:name]
      define :update_scheduled_task, action: :update
      define :record_scheduled_run, action: :record_run
      define :disable_scheduled_task, action: :disable
      define :destroy_scheduled_task, action: :destroy
    end

    resource Long.Agent.Group do
      define :create_group, action: :create
      define :list_groups, action: :read
      define :get_group, action: :read, get_by: [:id]
      define :update_group, action: :update
      define :destroy_group, action: :destroy
    end

    resource Long.Agent.Member do
      define :create_member, action: :create
      define :list_members, action: :read
      define :get_member, action: :read, get_by: [:id]
      define :list_members_for_group, action: :by_group, args: [:group_id]
      define :get_member_by_bind_code, action: :by_bind_code, args: [:bind_code], not_found_error?: false
      define :update_member, action: :update
      define :regenerate_member_bind_code, action: :regenerate_bind_code
      define :destroy_member, action: :destroy
    end

    resource Long.Agent.BotUser do
      define :create_bot_user, action: :create
      define :list_bot_users, action: :read
      define :update_bot_user, action: :update
      define :rotate_bot_session, action: :rotate_session
      define :bind_bot_user_member, action: :bind_member
      define :destroy_bot_user, action: :destroy
      define :get_bot_user_for_session, action: :by_session, args: [:session_id]
    end

    resource Long.Agent.WechatCredential do
      define :upsert_wechat_credential, action: :upsert
      define :list_wechat_credentials, action: :read
      define :get_wechat_credential, action: :read, get_by: [:name]
      define :update_wechat_credential_buf, action: :update_buf
      define :set_wechat_credential_member, action: :set_member
      define :set_wechat_credential_locale, action: :set_locale
      define :destroy_wechat_credential, action: :destroy
    end

    resource Long.Agent.TelegramCredential do
      define :upsert_telegram_credential, action: :upsert
      define :list_telegram_credentials, action: :read
      define :get_telegram_credential, action: :read, get_by: [:name]
      define :update_telegram_credential, action: :update
      define :update_telegram_credential_username, action: :update_username
      define :set_telegram_credential_member, action: :set_member
      define :set_telegram_credential_locale, action: :set_locale
      define :destroy_telegram_credential, action: :destroy
    end

    resource Long.Agent.Phrase do
      define :upsert_phrase, action: :upsert
      define :list_phrases, action: :read
      define :destroy_phrase, action: :destroy
    end

    resource Long.Agent.Secret do
      define :put_secret, action: :upsert
      define :list_secrets, action: :read
      define :get_secret_by_name, action: :read, get_by: [:name]
      define :update_secret, action: :update
      define :destroy_secret, action: :destroy
    end
  end

  @doc """
  Return the alias of the LLM marked as `default`, or the first
  enabled row when nothing is explicitly defaulted, or `nil` if no
  LLMs are configured. Used by chat-bootstrap and Bots to pick an
  alias when the user/session didn't specify one.
  """
  @spec default_llm_alias() :: String.t() | nil
  def default_llm_alias do
    case list_llms() do
      {:ok, rows} ->
        enabled = Enum.filter(rows, & &1.enabled)

        cond do
          row = Enum.find(enabled, & &1.default) -> row.alias
          first = List.first(enabled) -> first.alias
          true -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  The `Member` behind a session, or `nil` when there's no member to act as.

  Resolution hinges on one distinction — "no bot account" vs "a bot account
  that simply hasn't bound yet":

    * a bot chat bound (`/bind`) to a member → that member;
    * a bot chat that exists but is **unbound** → `nil`. An unbound account
      is a stranger talking to a hosted bot; it must NOT inherit the owner's
      powers (skills, `notify_member`, the owner's code workspace);
    * a web `/chat` session (no bot account at all) → `default_member/0`,
      the owner, because the web console *is* the owner's own surface;
    * `nil` if no members exist.

  The old code folded "unbound bot account" into the owner fallback, so an
  unbound Telegram/WeChat user was silently treated as the owner — a
  privilege-escalation hole this guards against.
  """
  @spec member_for_session(String.t()) :: Long.Agent.Member.t() | nil
  def member_for_session(session_id) when is_binary(session_id) do
    case get_bot_user_for_session(session_id) do
      {:ok, %{member_id: mid}} when is_binary(mid) ->
        case get_member(mid) do
          {:ok, member} -> member
          _ -> nil
        end

      # A bot account present but not yet bound to a member — a stranger on a
      # hosted bot. Genuinely unbound: do not impersonate the owner.
      {:ok, _unbound} ->
        nil

      # No bot account at all → a web `/chat` console, which acts as the owner.
      _ ->
        default_member()
    end
  end

  @doc "Just the member's id for `session_id` (incl. the web-chat fallback), or `nil`."
  @spec member_id_for_session(String.t()) :: String.t() | nil
  def member_id_for_session(session_id) when is_binary(session_id) do
    case member_for_session(session_id) do
      %{id: id} -> id
      _ -> nil
    end
  end

  @doc """
  Inbound-file directory for a session: `<that session's code_run workspace>/inbox`.
  A bound member → `members/<id>/inbox`; an unbound session (no member) → its own
  isolated `unbound/<session_id>/inbox`. Staging inbound files here — the SAME dir
  code_run is sandboxed to — is what lets the agent open them, for bound and
  unbound chats alike: a no-member chat still gets its own private workspace home,
  not the owner's and not an unreachable global inbox.
  """
  @spec session_inbox(String.t()) :: String.t()
  def session_inbox(session_id) when is_binary(session_id) do
    workspace_root()
    |> Long.Agent.DenoEnv.session_workspace(member_id_for_session(session_id), session_id)
    |> Path.join("inbox")
  end

  @doc """
  The member a web `/chat` session acts as when no chat account is bound —
  the owner. Prefers the `:self` member (the owner's own record), then any
  `:owner`-role member, then the first member; `nil` if there are none.
  """
  @spec default_member() :: Long.Agent.Member.t() | nil
  def default_member do
    case list_members() do
      {:ok, [_ | _] = members} ->
        Enum.find(members, &(&1.relation == :self)) ||
          Enum.find(members, &(&1.role == :owner)) ||
          List.first(members)

      _ ->
        nil
    end
  end

  @doc """
  Propagate a hosted account's member assignment onto the chat identities
  (`BotUser` rows) that arrived on it, so a freshly-assigned account is
  reachable for outbound `notify_member` immediately — without waiting for
  the next inbound message to lazily backfill it (see `Long.Agent.Bots`).

  Mirrors the inbound rule: an assigned account is authoritative over the
  member of every chat that arrives on it, so all of its bot_users adopt the
  assignment. A nil assignment is a no-op — un-assigning a hosted account
  keeps any explicit `/bind`.
  """
  @spec reassign_bot_users(atom(), String.t(), String.t() | nil) :: :ok
  def reassign_bot_users(_platform, _credential_name, nil), do: :ok

  def reassign_bot_users(platform, credential_name, member_id)
      when is_atom(platform) and is_binary(credential_name) and is_binary(member_id) do
    {:ok, users} = list_bot_users()

    users
    |> Enum.filter(&(&1.platform == platform and &1.credential_name == credential_name))
    |> Enum.reject(&(&1.member_id == member_id))
    |> Enum.each(&bind_bot_user_member(&1, %{member_id: member_id}))

    :ok
  end

  # `after_action` hooks for the credential `set_member` actions — thin
  # adapters onto reassign_bot_users/3 so both credential resources share one
  # implementation (mirrors the named-callback style in Long.Agent.Session).
  @doc false
  def reassign_wechat_bot_users(_changeset, credential, _context) do
    reassign_bot_users(:wechat, credential.name, credential.member_id)
    {:ok, credential}
  end

  @doc false
  def reassign_telegram_bot_users(_changeset, credential, _context) do
    reassign_bot_users(:telegram, credential.name, credential.member_id)
    {:ok, credential}
  end

  @doc "Filesystem root the agent's file tools and inbound media live under."
  @spec workspace_root() :: String.t()
  def workspace_root,
    do:
      Application.get_env(:long, Long.Agent, [])[:workspace_root] ||
        Path.expand("priv/agent/workspace", File.cwd!())

  @doc """
  Directory holding a web `/chat` session's uploaded attachments. Kept under
  the workspace root so the agent's file_read/code_run path guard can reach
  them, and isolated per session so the media route can serve them safely.
  """
  @spec web_inbox_dir(String.t()) :: String.t()
  def web_inbox_dir(session_id) when is_binary(session_id),
    do: Path.join([workspace_root(), "web_inbox", session_id])

  @doc "True for paths we treat as inline-renderable / vision-capable images."
  @spec image?(term()) :: boolean()
  def image?(path) when is_binary(path),
    do: path |> Path.extname() |> String.downcase() |> then(&(&1 in ~w(.jpg .jpeg .png .gif .webp .bmp)))

  def image?(_), do: false

  @doc """
  Copy a source file into the session's web_inbox under a sanitized,
  collision-free name and return the destination path. Both the chat upload
  path and the agent's send_media output stage media through here, so the
  media route serves them identically.
  """
  @spec stage_in_web_inbox(String.t(), String.t(), String.t() | nil) :: String.t()
  def stage_in_web_inbox(session_id, src_path, name \\ nil) do
    dir = web_inbox_dir(session_id)
    File.mkdir_p!(dir)
    dest = unique_web_inbox_path(dir, name || Path.basename(src_path))
    File.cp!(src_path, dest)
    dest
  end

  @doc """
  The user's timezone for local↔UTC conversion — the stored `user_timezone`
  setting if set (by the user via `set_timezone` or the admin in /manage), else
  the configured default. Used by `Long.Agent.Schedule.timezone_note/0`.
  """
  @spec user_timezone() :: String.t()
  def user_timezone do
    case get_setting("user_timezone") do
      {:ok, %{value: tz}} when is_binary(tz) and tz != "" -> tz
      _ -> Application.get_env(:long, :user_timezone, "Asia/Shanghai")
    end
  end

  @doc """
  Persist the user timezone if `tz` is a valid IANA zone — the single write path
  shared by the `set_timezone` tool and the admin UI. Returns `:ok`, or `:error`
  for an unknown zone / non-binary (so callers can ignore half-typed input).
  """
  @spec put_user_timezone(term()) :: :ok | :error
  def put_user_timezone(tz) when is_binary(tz) do
    if tz in Tzdata.zone_list() do
      {:ok, _} = put_setting(%{key: "user_timezone", value: tz})
      :ok
    else
      :error
    end
  end

  def put_user_timezone(_), do: :error

  # ── Silent reflection (autonomous "tidy your own memory" loop) ────────

  @reflection_name_prefix "reflection:"

  @doc "Deterministic per-session name for the reflection ScheduledTask (`:name` is globally unique)."
  @spec reflection_task_name(String.t()) :: String.t()
  def reflection_task_name(session_id) when is_binary(session_id),
    do: @reflection_name_prefix <> session_id

  @doc """
  Timestamp of the most recent **human** message in a session — `role: :user`
  AND `internal == false`, so the synthetic reflection-trigger user rows (which
  are marked internal) never count as activity. Returns `nil` for a session with
  no human messages (e.g. freshly `/clear`ed). Drives the reflection activity gate.
  """
  @spec last_human_message_at(String.t()) :: DateTime.t() | nil
  def last_human_message_at(session_id) when is_binary(session_id) do
    latest_message_at(session_id, role: :user, internal: false)
  end

  @doc """
  Timestamp of the most recent **internal** (silent-reflection) message in a
  session, or `nil` if it has never reflected. Paired with
  `last_human_message_at/1` it forms the crash-safe activity gate: reflect
  iff there's human activity newer than the last reflection. Because both
  sides are real `message.inserted_at` values (same usec precision, and an
  internal row exists only if a reflection actually ran), the gate never
  spuriously double-fires and never permanently skips after a lost turn.
  """
  @spec last_internal_message_at(String.t()) :: DateTime.t() | nil
  def last_internal_message_at(session_id) when is_binary(session_id) do
    latest_message_at(session_id, internal: true)
  end

  defp latest_message_at(session_id, filters) do
    require Ash.Query

    role = Keyword.get(filters, :role)
    internal = Keyword.fetch!(filters, :internal)

    Long.Agent.Message
    |> Ash.Query.filter(session_id == ^session_id and internal == ^internal)
    |> then(fn q -> if role, do: Ash.Query.filter(q, role == ^role), else: q end)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one()
    |> case do
      {:ok, %{inserted_at: at}} -> at
      _ -> nil
    end
  end

  @doc """
  Idempotently ensure a daily silent-reflection task exists for `session_id`.

    * already has one → `{:ok, task}` (no duplicate; `:name` is globally unique);
    * session has no member to act for (an unbound stranger on a hosted bot) →
      `{:ok, :skipped}` — we don't reflect over a stranger's chat;
    * otherwise create one: `silent: true`, `repeat: :daily`, an off-peak UTC
      `schedule_time` whose **minute is jittered by a hash of the session id** so a
      fleet of sessions doesn't stampede the LLM provider at one instant,
      `max_delay_hours: 1` and an explicit `next_run_at` so a backfill run never
      fires the whole fleet immediately on the next SchedulerTick.
  """
  @spec ensure_reflection_task(String.t(), keyword()) ::
          {:ok, Long.Agent.ScheduledTask.t() | :skipped} | {:error, term()}
  def ensure_reflection_task(session_id, opts \\ []) when is_binary(session_id) do
    name = reflection_task_name(session_id)

    case get_scheduled_task_by_name(name) do
      # Re-enable a task that L4 archival disabled, now that the session is
      # active again, and re-arm its next run.
      {:ok, %Long.Agent.ScheduledTask{enabled: false} = task} ->
        next = Long.Agent.Schedule.compute_next_run_at(task, DateTime.utc_now())
        update_scheduled_task(task, %{enabled: true, next_run_at: next})

      {:ok, %Long.Agent.ScheduledTask{} = task} ->
        {:ok, task}

      _ ->
        if is_nil(member_id_for_session(session_id)) do
          {:ok, :skipped}
        else
          create_reflection_task(session_id, name, opts)
        end
    end
  end

  defp create_reflection_task(session_id, name, opts) do
    hour = Keyword.get(opts, :hour, reflection_hour())
    minute = rem(:erlang.phash2(session_id, 60), 60)
    schedule_time = Long.Agent.Schedule.format_hhmm(hour, minute)

    seed = %Long.Agent.ScheduledTask{repeat: :daily, schedule_time: schedule_time}
    next = Long.Agent.Schedule.compute_next_run_at(seed, DateTime.utc_now())

    create_scheduled_task(%{
      name: name,
      session_id: session_id,
      prompt: Long.Jido.Loop.reflection_trigger_prompt(),
      repeat: :daily,
      schedule_time: schedule_time,
      silent: true,
      max_delay_hours: 1,
      next_run_at: next
    })
    |> case do
      {:ok, task} ->
        {:ok, task}

      {:error, _} ->
        # Lost a create race on the globally-unique `:name` — re-read the winner.
        case get_scheduled_task_by_name(name) do
          {:ok, task} -> {:ok, task}
          other -> other
        end
    end
  end

  @doc "Disable a session's reflection task (called when its session is archived)."
  @spec disable_reflection_task(String.t()) :: :ok
  def disable_reflection_task(session_id) when is_binary(session_id) do
    case get_scheduled_task_by_name(reflection_task_name(session_id)) do
      {:ok, %Long.Agent.ScheduledTask{enabled: true} = task} ->
        _ = disable_scheduled_task(task)
        :ok

      _ ->
        :ok
    end
  end

  @doc "Whether silent reflection is enabled for this instance (kill switch)."
  @spec reflection_enabled?() :: boolean()
  def reflection_enabled?,
    do: Keyword.get(reflection_config(), :enabled, true)

  defp reflection_hour, do: Keyword.get(reflection_config(), :hour, 18)

  defp reflection_config, do: Application.get_env(:long, Long.Agent.Reflection, [])

  defp unique_web_inbox_path(dir, name) do
    safe = name |> Path.basename() |> String.replace(~r/[^\w.\-]+/u, "_")
    candidate = Path.join(dir, safe)

    if File.exists?(candidate) do
      ext = Path.extname(safe)
      base = Path.basename(safe, ext)
      Path.join(dir, "#{base}-#{System.unique_integer([:positive])}#{ext}")
    else
      candidate
    end
  end
end
