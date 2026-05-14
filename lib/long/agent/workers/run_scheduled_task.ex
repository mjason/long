defmodule Long.Agent.Workers.RunScheduledTask do
  @moduledoc """
  Fires the synthetic prompt of a `Long.Agent.ScheduledTask` into its
  session by delegating to `Long.Agent.SessionRunner.send_user_message/3`.

  The actual agent loop runs in a Task under the SessionRunner; this Oban
  worker only confirms the trigger was dispatched (returns `:ok` once the
  Task is spawned).
  """

  use Oban.Worker, queue: :agent, max_attempts: 5

  alias Long.Agent
  alias Long.Agent.SessionRunner

  @impl true
  def perform(%Oban.Job{args: %{"task_id" => task_id}}) do
    with {:ok, task} <- Agent.get_scheduled_task(task_id) do
      case SessionRunner.send_user_message(task.session_id, task.prompt) do
        {:ok, _pid} -> :ok
        other -> {:error, inspect(other)}
      end
    end
  end
end
