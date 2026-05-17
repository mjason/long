defmodule Long.Agent.SessionPubSub do
  @moduledoc """
  Global PubSub channel for session lifecycle events.

  Anyone interested in "any session was created / updated / destroyed"
  (e.g. the chat LiveView's sidebar) subscribes to topic `"sessions"`.
  Per-session events still go through `agent_session:<uuid>` —
  `Long.Jido.TitleGen` and `Long.Agent.Server` continue to broadcast
  there for subscribers tied to a specific conversation.
  """

  @topic "sessions"

  def topic, do: @topic
  def subscribe, do: Phoenix.PubSub.subscribe(Long.PubSub, @topic)
  def unsubscribe, do: Phoenix.PubSub.unsubscribe(Long.PubSub, @topic)

  @doc false
  def broadcast_created(_changeset, %{id: _} = session, _ctx) do
    Phoenix.PubSub.broadcast(Long.PubSub, @topic, {:session_created, session})
    {:ok, session}
  end

  @doc false
  def broadcast_updated(_changeset, %{id: _} = session, _ctx) do
    Phoenix.PubSub.broadcast(Long.PubSub, @topic, {:session_updated, session})
    {:ok, session}
  end

  @doc false
  def broadcast_destroyed(_changeset, %{id: id} = session, _ctx) do
    Phoenix.PubSub.broadcast(Long.PubSub, @topic, {:session_destroyed, id})
    {:ok, session}
  end
end
