defmodule Long.Agent.SessionClear do
  @moduledoc """
  Wipe a session's runtime + persistent state without destroying the
  session row itself: keeps the same id (URL / WeChat thread stable)
  but drops messages, session memories, checkpoint, summary, snapshot,
  and any in-flight Long.Agent.Server.

  Used by:
    - chat UI's `/clear` magic command
    - WeChat / Telegram / Feishu bot's `/clear` magic command

  Synchronous: callers can rely on the DB rows being gone when this
  returns. The Server is also terminated before the DB wipe to
  prevent it from re-snapshotting state mid-cleanup.
  """

  require Ash.Query

  alias Long.Agent

  @doc """
  Clear `session_id` and return `:ok`. Safe to call when the session
  has no messages / no Server / no checkpoint — each step is best-effort.
  """
  def clear(session_id) when is_binary(session_id) do
    Long.Agent.Server.terminate_session(session_id)

    _ =
      Long.Agent.Message
      |> Ash.Query.filter(session_id == ^session_id)
      |> Ash.bulk_destroy(:destroy, %{}, strategy: :stream, return_errors?: false)

    _ =
      Long.Agent.SessionMemory
      |> Ash.Query.filter(session_id == ^session_id)
      |> Ash.bulk_destroy(:destroy, %{}, strategy: :stream, return_errors?: false)

    case Agent.get_checkpoint(session_id) do
      {:ok, checkpoint} -> Ash.destroy(checkpoint)
      _ -> :ok
    end

    with {:ok, session} <- Agent.get_session(session_id) do
      Agent.update_session(session, %{summary: nil, summary_through_inserted_at: nil})
    end

    # Tell any LiveView / bot watcher that's looking at this session to
    # refresh — the messages list and the snapshot just got wiped.
    Phoenix.PubSub.broadcast(
      Long.PubSub,
      "agent_session:" <> session_id,
      :session_cleared
    )

    :ok
  end
end
