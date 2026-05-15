defmodule Long.Jido.Tools.AgentStatus do
  @moduledoc """
  Lets the agent answer "what's the current task / how far along are
  you?" without inventing keyword detection. Reads the in-memory
  `Long.Agent.Activity` slot for this session; no DB hit.
  """

  use Jido.Action,
    name: "agent_status",
    description:
      "Look up what the current agent loop on this session is doing. " <>
        "Use this when the user asks about your progress / what you're " <>
        "working on / why you're taking a while. Returns runtime, " <>
        "current turn, and current tool (or `{status: \"idle\"}` when " <>
        "the session has no active loop). No arguments.",
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
        snapshot = Activity.snapshot(sid)

        case snapshot.owner do
          nil ->
            {:ok,
             %{
               status: "idle",
               session_id: sid,
               queued_messages: snapshot.queue_length,
               pending_btws: snapshot.pending_btws
             }}

          info ->
            {:ok,
             %{
               status: "running",
               session_id: sid,
               runtime_seconds: Duration.seconds_since(info.since),
               turn: info.turn,
               tool: info.tool,
               description: Activity.describe(info),
               queued_messages: snapshot.queue_length,
               pending_btws: snapshot.pending_btws
             }}
        end

      _ ->
        {:ok, %{status: "error", msg: "session_id missing from tool context"}}
    end
  end
end
