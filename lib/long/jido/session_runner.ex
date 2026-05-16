defmodule Long.Jido.SessionRunner do
  @moduledoc """
  Thin shim around `Long.Agent.Server`. Owns the `agent_session:<uuid>`
  PubSub topic format used by LiveView / bots, plus the default tool
  list. New code should call `Long.Agent.Server` directly.
  """

  alias Long.Agent

  @topic_prefix "agent_session:"

  @default_tools [
    Long.Jido.Tools.CodeRun,
    Long.Jido.Tools.FileRead,
    Long.Jido.Tools.FileWrite,
    Long.Jido.Tools.FilePatch,
    Long.Jido.Tools.HttpFetch,
    Long.Jido.Tools.UpdateWorkingCheckpoint,
    Long.Jido.Tools.MemoryRemember,
    Long.Jido.Tools.MemoryRecall,
    Long.Jido.Tools.StartLongTermUpdate,
    Long.Jido.Tools.WebSearch,
    Long.Jido.Tools.WebScan,
    Long.Jido.Tools.WebExecuteJs,
    Long.Jido.Tools.ScheduleTask,
    Long.Jido.Tools.ListScheduledTasks,
    Long.Jido.Tools.CancelScheduledTask,
    Long.Jido.Tools.SendMedia,
    Long.Jido.Tools.AskUser,
    Long.Jido.Tools.AgentStatus,
    Long.Jido.Tools.SkillSearch,
    Long.Jido.Tools.SkillRead,
    Long.Jido.Tools.SkillReindex
  ]

  def topic(session_id), do: @topic_prefix <> session_id
  def subscribe(session_id), do: Phoenix.PubSub.subscribe(Long.PubSub, topic(session_id))
  def unsubscribe(session_id), do: Phoenix.PubSub.unsubscribe(Long.PubSub, topic(session_id))

  @doc "Default tool list — exposed so `Long.Agent.Server` can reuse it."
  def default_tools, do: @default_tools

  def send_user_message(session_id, text, opts \\ [])
      when is_binary(session_id) and is_binary(text) do
    case Agent.get_session(session_id) do
      {:ok, _session} -> Long.Agent.Server.send_user_message(session_id, text, opts)
      err -> err
    end
  end
end
