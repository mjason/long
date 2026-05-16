defmodule Long.Agent.Workers.RunScheduledTask do
  @moduledoc """
  Fires the synthetic prompt of a `Long.Agent.ScheduledTask` into its
  session.

  Two dispatch modes depending on whether the session has an associated
  `Long.Agent.BotUser`:

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

  use Oban.Worker, queue: :agent, max_attempts: 5

  require Logger

  alias Long.Agent
  alias Long.Agent.Bots
  alias Long.Agent.Bots.Outbound
  alias Long.SessionRunner

  @impl true
  def perform(%Oban.Job{args: %{"task_id" => task_id}}) do
    with {:ok, task} <- Agent.get_scheduled_task(task_id) do
      case lookup_bot_user(task.session_id) do
        nil -> fire_async(task)
        bot_user -> fire_sync_and_push(task, bot_user)
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
        case Outbound.push(bot_user, result) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "RunScheduledTask: outbound push failed " <>
                "(platform=#{bot_user.platform}, session=#{task.session_id}): #{inspect(reason)}"
            )

            # Don't retry — Oban would replay the prompt and double-bill the
            # LLM. The reply is already persisted in the session; user can
            # check via the LiveView UI.
            :ok
        end

      {:error, reason} ->
        Logger.error(
          "RunScheduledTask: agent loop failed " <>
            "(session=#{task.session_id}): #{inspect(reason)}"
        )

        {:error, inspect(reason)}
    end
  end
end
