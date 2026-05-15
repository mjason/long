defmodule Long.Jido.Tools.AgentStatus do
  @moduledoc """
  Lets the agent answer "what other tasks are running on this session
  right now?" — typically when the user asks "你在干嘛?" / "what are
  you working on?" / "进度怎么样" mid-flight. Reads the in-memory
  `Long.Agent.Activity` registry; no DB hit.

  Returns the list of active watchers (could be ≥1 if the user sent
  multiple messages in quick succession). Each entry includes when it
  started, the current ReAct turn, and which tool (if any) is
  currently running.
  """

  use Jido.Action,
    name: "agent_status",
    description:
      "Look up what agent loops are currently running on this session. " <>
        "Use this when the user asks about your current progress / what " <>
        "you're working on / why you're taking a while. Returns a list " <>
        "describing each task's runtime, current turn, and current tool. " <>
        "No arguments.",
    category: "introspection",
    tags: ["session", "status"],
    vsn: "1.0.0",
    schema: Zoi.object(%{})

  alias Long.Agent.Activity
  alias Long.Util.Duration

  @impl true
  def run(_params, ctx) do
    case ctx[:session_id] do
      sid when is_binary(sid) ->
        {:ok,
         %{
           status: "success",
           session_id: sid,
           tasks: Enum.map(Activity.lookup(sid), &format/1)
         }}

      _ ->
        {:ok, %{status: "error", msg: "session_id missing from tool context"}}
    end
  end

  defp format(info) do
    %{
      since_ms: info.since,
      runtime_seconds: Duration.seconds_since(info.since),
      turn: info.turn,
      tool: info.tool,
      description: Activity.describe(info)
    }
  end
end
