defmodule Long.Jido.SessionRunner do
  @moduledoc """
  Thin shim around `Long.Agent.Server`. Owns the `agent_session:<uuid>`
  PubSub topic format used by LiveView / bots, plus the default tool
  list. New code should call `Long.Agent.Server` directly.
  """

  alias Long.Agent

  @topic_prefix "agent_session:"

  # GraphQL is the single data-access tool for everything stored in
  # Ash resources (sessions, messages, memories, scheduled tasks,
  # working checkpoints, LLM configs, search configs, skills index).
  # Native tools below cover only the capabilities that don't fit a
  # GraphQL CRUD model — shell, files, web, user IO, skill body read.
  @default_tools [
    Long.Jido.Tools.GraphQL,
    Long.Jido.Tools.CodeRun,
    Long.Jido.Tools.FileRead,
    Long.Jido.Tools.FileWrite,
    Long.Jido.Tools.FilePatch,
    Long.Jido.Tools.HttpFetch,
    Long.Jido.Tools.WebSearch,
    Long.Jido.Tools.WebScan,
    Long.Jido.Tools.WebExecuteJs,
    Long.Jido.Tools.SendMedia,
    Long.Jido.Tools.NotifyMember,
    Long.Jido.Tools.AskUser,
    Long.Jido.Tools.SkillRead
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
