defmodule Long.Agent.Workers.L4Archive do
  @moduledoc """
  Periodic L4 archival worker. Mirrors the `_l4_t` cron block in
  `reflect/scheduler.py` — every N hours, snapshot sessions that have gone
  idle and don't yet have an archive row.

  Eligibility (configurable via `config :long, Long.Agent, archive: …`):

  - `:status` not `:archived`
  - At least one message exists
  - No `SessionArchive` row already references this session
  - Last message is older than `:idle_hours` (default 24h)

  After archiving, the session is moved to `:archived` status.
  """

  use Oban.Worker, queue: :agent, max_attempts: 3

  alias Long.Agent
  alias Long.Agent.Memory

  @default_idle_hours 24

  @impl true
  def perform(%Oban.Job{}) do
    idle_hours = idle_hours()
    cutoff = DateTime.add(DateTime.utc_now(), -idle_hours * 3600, :second)

    with {:ok, sessions} <- Agent.list_sessions(),
         {:ok, all_messages} <- Agent.list_messages(),
         {:ok, archives} <- Agent.list_archives() do
      archived_ids = MapSet.new(archives, & &1.original_session_id)
      message_index = Enum.group_by(all_messages, & &1.session_id)

      sessions
      |> Enum.reject(&(&1.status == :archived))
      |> Enum.reject(&MapSet.member?(archived_ids, &1.id))
      |> Enum.filter(&eligible?(&1, message_index[&1.id] || [], cutoff))
      |> Enum.each(&archive_one/1)
    end

    :ok
  end

  defp eligible?(_session, [], _cutoff), do: false

  defp eligible?(_session, messages, cutoff) do
    last_inserted_at = messages |> Enum.map(& &1.inserted_at) |> Enum.max(DateTime)
    DateTime.compare(last_inserted_at, cutoff) == :lt
  end

  defp archive_one(session) do
    case Memory.archive_session(session.id) do
      {:ok, _archive} ->
        Agent.archive_session(session.id)

      _ ->
        :skip
    end
  end

  defp idle_hours do
    case Application.get_env(:long, Long.Agent, [])[:archive] do
      cfg when is_list(cfg) -> Keyword.get(cfg, :idle_hours, @default_idle_hours)
      _ -> @default_idle_hours
    end
  end
end
