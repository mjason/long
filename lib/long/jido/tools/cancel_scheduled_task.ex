defmodule Long.Jido.Tools.CancelScheduledTask do
  @moduledoc """
  Cancel a scheduled task by name. Defaults to a destructive delete; pass
  `permanent: false` to merely disable the row so it can be re-enabled later.
  """

  use Jido.Action,
    name: "cancel_scheduled_task",
    description:
      "Cancel a scheduled task by name. Defaults to deleting it. Set " <>
        "`permanent=false` to only disable (so the row stays around).",
    category: "scheduling",
    tags: ["cron", "timer", "scheduler"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        name: Zoi.string(description: "Name of the scheduled task to cancel"),
        permanent:
          Zoi.boolean(description: "true → destroy row; false → just disable. Default true.")
          |> Zoi.optional()
          |> Zoi.default(true)
      })

  alias Long.Agent
  alias Long.Jido.Tools.Format

  @impl true
  def run(%{name: name}, _ctx) when name in [nil, ""] do
    {:ok, %{status: "error", msg: "name is required"}}
  end

  def run(params, ctx) do
    with {:ok, session_id} <- Format.require_session_id(ctx),
         {:ok, task} <- find_owned(params[:name], session_id),
         {:ok, action} <- cancel(task, Map.get(params, :permanent, true)) do
      {:ok, %{status: "success", name: task.name, action: action}}
    else
      {:error, msg} -> {:ok, %{status: "error", msg: msg}}
    end
  end

  defp find_owned(name, session_id) do
    case Agent.get_scheduled_task_by_name(name) do
      {:ok, %{session_id: ^session_id} = task} -> {:ok, task}
      {:ok, _other_session} -> {:error, "task #{inspect(name)} belongs to another session"}
      {:error, _} -> {:error, "no scheduled task named #{inspect(name)} in this session"}
    end
  end

  defp cancel(task, true) do
    case Agent.destroy_scheduled_task(task) do
      :ok -> {:ok, "destroyed"}
      {:ok, _} -> {:ok, "destroyed"}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  defp cancel(task, false) do
    case Agent.disable_scheduled_task(task) do
      {:ok, _} -> {:ok, "disabled"}
      {:error, e} -> {:error, inspect(e)}
    end
  end
end
