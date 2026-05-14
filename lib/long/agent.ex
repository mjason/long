defmodule Long.Agent do
  @moduledoc """
  Ash domain for the GenericAgent runtime ported into Long.

  Hosts session, message, memory (L1-L4), skill, and LLM-config resources.
  See `~/.claude/projects/-home-mj-dev-elixir-long/memory/project_genericagent_migration.md`
  for migration context.
  """

  use Ash.Domain,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
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
      define :append_message, action: :append
      define :list_messages, action: :read
    end

    resource Long.Agent.WorkingCheckpoint do
      define :upsert_checkpoint, action: :upsert
      define :get_checkpoint, action: :read, get_by: [:session_id]
    end

    resource Long.Agent.GlobalMemory do
      define :put_global_memory, action: :upsert
      define :list_global_memory, action: :read
      define :delete_global_memory, action: :destroy
    end

    resource Long.Agent.Skill do
      define :register_skill, action: :register
      define :list_skills, action: :read
      define :get_skill, action: :read, get_by: [:name]
      define :touch_skill, action: :touch, get_by: [:name]
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
      define :destroy_llm, action: :destroy
    end

    resource Long.Agent.ScheduledTask do
      define :create_scheduled_task, action: :create
      define :list_scheduled_tasks, action: :read
      define :get_scheduled_task, action: :read, get_by: [:id]
      define :get_scheduled_task_by_name, action: :read, get_by: [:name]
      define :update_scheduled_task, action: :update
      define :record_scheduled_run, action: :record_run
      define :disable_scheduled_task, action: :disable
      define :destroy_scheduled_task, action: :destroy
    end

    resource Long.Agent.BotUser do
      define :create_bot_user, action: :create
      define :list_bot_users, action: :read
      define :update_bot_user, action: :update
      define :rotate_bot_session, action: :rotate_session
      define :destroy_bot_user, action: :destroy
    end
  end
end
