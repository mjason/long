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

    resource Long.Agent.Household do
      define :create_household, action: :create
      define :list_households, action: :read
      define :get_household, action: :read, get_by: [:id]
      define :update_household, action: :update
      define :destroy_household, action: :destroy
    end

    resource Long.Agent.HouseholdMember do
      define :create_member, action: :create
      define :list_members, action: :read
      define :get_member, action: :read, get_by: [:id]
      define :list_members_for_household, action: :by_household, args: [:household_id]
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
  The `HouseholdMember` bound to a session's chat account, or `nil` for an
  unbound / web-chat session. Used to scope per-member skills and to
  resolve the caller for `notify_member`.
  """
  @spec member_for_session(String.t()) :: Long.Agent.HouseholdMember.t() | nil
  def member_for_session(session_id) when is_binary(session_id) do
    with {:ok, %{member_id: mid}} when is_binary(mid) <- get_bot_user_for_session(session_id),
         {:ok, member} <- get_member(mid) do
      member
    else
      _ -> nil
    end
  end

  @doc "Just the bound member's id for `session_id`, or `nil`."
  @spec member_id_for_session(String.t()) :: String.t() | nil
  def member_id_for_session(session_id) when is_binary(session_id) do
    case get_bot_user_for_session(session_id) do
      {:ok, %{member_id: mid}} -> mid
      _ -> nil
    end
  end
end
