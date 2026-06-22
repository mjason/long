defmodule Long.Agent.Workers.RunScheduledTask do
  @moduledoc """
  Fires the synthetic prompt of a `Long.Agent.ScheduledTask` into its
  session.

  Three dispatch modes:

    * Silent (`task.silent`) → a SILENT REFLECTION turn via
      `Long.Agent.Server` with `reflection?: true, internal: true`. It
      never touches `Outbound` and runs a reduced, push-free tool set, so
      it can't reach a channel or another member's data; its rows are
      `internal` and emit no PubSub, so it's invisible to web + bot. Gated
      by an activity check (skip when nothing new) and the instance kill
      switch. Runs regardless of whether the session is bot-backed.
    * Bot session → run the agent loop **synchronously** via
      `Long.Agent.Bots.run_on_session/3` (so we can observe the loop's
      final reply) and push the result to the originating platform via
      `Long.Agent.Bots.Outbound.push/2`. Without this, scheduled prompts
      would compute a reply but it would only land in the DB — no one is
      subscribed to the session's PubSub topic at firing time.
    * Non-bot session (LiveView, CLI, …) → fire-and-forget via
      `SessionRunner.send_user_message/2`; whichever browser tab is
      subscribed will render the reply.
  """

  # `unique` is a multi-user safety net: under load two overlapping
  # SchedulerTick runs could both see the same due task before either
  # records the run. Deduping by args (task_id) within a short window
  # stops a task being fired twice — and a double silent-reflection would
  # double-bill the LLM. Daily tasks are already protected by next_run_at
  # advancement; this covers the racy edges.
  use Oban.Worker, queue: :agent, max_attempts: 5, unique: [period: 120, fields: [:args]]

  require Logger

  alias Long.Agent
  alias Long.Agent.Bots
  alias Long.Agent.Bots.Outbound
  alias Long.Agent.Server
  alias Long.SessionRunner

  # A push is cheap (no LLM), so a transient delivery failure (e.g. a flaky
  # network at fire time) is retried IN PLACE rather than by replaying the whole
  # Oban job — which would re-run the agent loop and double-bill the LLM.
  @push_attempts 3
  @push_retry_delay_ms 2_000

  @impl true
  def perform(%Oban.Job{args: %{"task_id" => task_id}}) do
    with {:ok, task} <- Agent.get_scheduled_task(task_id) do
      cond do
        task.silent ->
          fire_silent(task)

        true ->
          case lookup_bot_user(task.session_id) do
            nil -> fire_async(task)
            bot_user -> fire_sync_and_push(task, bot_user)
          end
      end
    end
  end

  # A silent reflection turn. Always returns `:ok` so Oban never replays
  # it (a replay would re-run the prompt and double-bill the LLM); a turn
  # lost to a crash simply reflects again on the next schedule. Silence is
  # structural in `Long.Agent.Server` (reduced tool set + internal rows +
  # PubSub suppression), not in this dispatcher.
  defp fire_silent(task) do
    cond do
      not Agent.reflection_enabled?() ->
        :ok

      not reflection_due?(task) ->
        # Activity gate: no fresh human input since the last reflection —
        # skip the whole LLM turn so idle sessions cost nothing.
        :ok

      true ->
        case Server.send_user_message(task.session_id, task.prompt,
               reflection?: true,
               internal: true
             ) do
          :ok ->
            :ok

          other ->
            Logger.warning(
              "RunScheduledTask: silent reflection dispatch failed " <>
                "(session=#{task.session_id}): #{inspect(other)}"
            )

            :ok
        end
    end
  end

  # Reflect only when there's genuinely something new: a human (non-internal
  # `:user`) message exists AND it's newer than the last reflection. The
  # "last reflection" anchor is the newest INTERNAL message row — which
  # exists only if a reflection actually ran — so a turn lost to a crash
  # leaves the gate open (it retries) instead of being silently stamped
  # done. A `/clear`ed session has no human messages → nil → skip.
  defp reflection_due?(task) do
    case Agent.last_human_message_at(task.session_id) do
      nil ->
        false

      human_at ->
        case Agent.last_internal_message_at(task.session_id) do
          nil -> true
          reflected_at -> DateTime.compare(human_at, reflected_at) == :gt
        end
    end
  end

  defp lookup_bot_user(session_id) do
    case Agent.get_bot_user_for_session(session_id) do
      {:ok, user} -> user
      _ -> nil
    end
  end

  defp fire_async(task) do
    case SessionRunner.send_user_message(task.session_id, task.prompt) do
      :ok -> :ok
      other -> {:error, inspect(other)}
    end
  end

  defp fire_sync_and_push(task, bot_user) do
    case Bots.run_on_session(task.session_id, task.prompt) do
      {:ok, result} ->
        if empty_reply?(result) do
          # The loop ran but we collected nothing to deliver — push would be a
          # silent no-op. Surface it instead of quietly delivering nothing.
          Logger.warning(
            "RunScheduledTask: agent produced no deliverable reply " <>
              "(session=#{task.session_id}); nothing to push"
          )
        end

        deliver(task, bot_user, result)

      {:error, reason} ->
        Logger.error(
          "RunScheduledTask: agent loop failed " <>
            "(session=#{task.session_id}): #{inspect(reason)}"
        )

        {:error, inspect(reason)}
    end
  end

  # Push the reply, retrying transient failures in place. After the last
  # attempt, surface loudly (ErrorTracker) instead of swallowing it — a failed
  # scheduled push used to vanish with no trace. Still returns `:ok`: the reply
  # is persisted and we must NOT replay the LLM via an Oban retry.
  defp deliver(task, bot_user, result, attempt \\ 1) do
    case Outbound.push(bot_user, result) do
      :ok ->
        :ok

      {:error, reason} when attempt < @push_attempts ->
        Logger.warning(
          "RunScheduledTask: push attempt #{attempt}/#{@push_attempts} failed " <>
            "(platform=#{bot_user.platform}, session=#{task.session_id}): #{inspect(reason)}; retrying"
        )

        Process.sleep(@push_retry_delay_ms)
        deliver(task, bot_user, result, attempt + 1)

      {:error, reason} ->
        Logger.error(
          "RunScheduledTask: push FAILED after #{@push_attempts} attempts " <>
            "(platform=#{bot_user.platform}, session=#{task.session_id}): #{inspect(reason)}"
        )

        report_push_failure(task, bot_user, reason)
        :ok
    end
  end

  defp report_push_failure(task, bot_user, reason) do
    ErrorTracker.report(
      %RuntimeError{message: "scheduled push failed after retries: #{inspect(reason)}"},
      [],
      %{
        source: "run_scheduled_task",
        task: task.name,
        session_id: task.session_id,
        platform: bot_user.platform
      }
    )

    :ok
  rescue
    _ -> :ok
  end

  defp empty_reply?(result) do
    String.trim(Map.get(result, :text, "") || "") == "" and
      (Map.get(result, :attachments, []) || []) == [] and
      is_nil(Map.get(result, :ask))
  end
end
