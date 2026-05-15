defmodule Long.Jido.Tools.ScheduleTask do
  @moduledoc """
  Create a recurring (or one-shot) scheduled prompt that fires into THIS
  session. The scheduler tick (`Long.Agent.Workers.SchedulerTick`) runs
  every minute, sees the row become due, and dispatches the prompt as if
  the user had sent it.
  """

  use Jido.Action,
    name: "schedule_task",
    description: """
    Schedule a prompt to fire into THIS session at a future time, once
    or on a recurring cadence. All times are UTC.

    `repeat` selects the cadence and decides which other args matter:

      - "once"             — fires once. Provide `next_run_at` (ISO8601 UTC).
      - "daily"            — every day at `at` ("HH:MM" UTC).
      - "weekday"          — Mon–Fri at `at`.
      - "weekly"           — once a week at `at`.
      - "monthly"          — once a month at `at`.
      - "every_n_hours"    — every `every` hours starting now.
      - "every_n_minutes"  — every `every` minutes starting now.

    Examples:
      schedule_task(name="morning_brief", prompt="Summarize unread mail",
                    repeat="daily", at="09:00")
      schedule_task(name="poll_jobs", prompt="Check CI status",
                    repeat="every_n_minutes", every=15)
      schedule_task(name="release_check", prompt="Verify deploy",
                    repeat="once", next_run_at="2026-05-15T02:30:00Z")
    """,
    category: "scheduling",
    tags: ["cron", "timer", "scheduler"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        name: Zoi.string(description: "Unique task name"),
        prompt: Zoi.string(description: "User-message text to inject when the task fires"),
        repeat:
          Zoi.string(
            description:
              "once | daily | weekday | weekly | monthly | every_n_hours | every_n_minutes"
          )
          |> Zoi.optional()
          |> Zoi.default("daily"),
        at:
          Zoi.string(description: ~s|UTC "HH:MM" for time-of-day repeats|)
          |> Zoi.optional(),
        every:
          Zoi.integer(description: "Step for every_n_hours / every_n_minutes")
          |> Zoi.optional(),
        next_run_at:
          Zoi.string(description: "ISO8601 UTC time for `once` (or to override first fire)")
          |> Zoi.optional(),
        max_delay_hours:
          Zoi.integer(description: "If we miss by more than this, skip rather than fire late")
          |> Zoi.optional()
      })

  alias Long.Agent
  alias Long.Agent.{Schedule, ScheduledTask}
  alias Long.Jido.Tools.Format

  @impl true
  def run(params, ctx) do
    with {:ok, session_id} <- Format.require_session_id(ctx),
         {:ok, name} <- require_nonempty(params[:name], "name"),
         {:ok, prompt} <- require_nonempty(params[:prompt], "prompt"),
         {:ok, repeat} <- parse_repeat(params[:repeat] || "daily") do
      attrs = build_attrs(session_id, name, prompt, repeat, params)

      case Agent.create_scheduled_task(attrs) do
        {:ok, task} ->
          {:ok,
           %{
             status: "success",
             id: task.id,
             name: task.name,
             repeat: to_string(task.repeat),
             next_run_at: Format.iso8601(task.next_run_at)
           }}

        {:error, e} ->
          {:ok, %{status: "error", msg: Format.ash_error_message(e)}}
      end
    else
      {:error, msg} -> {:ok, %{status: "error", msg: msg}}
    end
  end

  defp require_nonempty(value, field) do
    case value do
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> {:error, "#{field} must not be empty"}
    end
  end

  defp parse_repeat("once"), do: {:ok, :once}
  defp parse_repeat("daily"), do: {:ok, :daily}
  defp parse_repeat("weekday"), do: {:ok, :weekday}
  defp parse_repeat("weekly"), do: {:ok, :weekly}
  defp parse_repeat("monthly"), do: {:ok, :monthly}
  defp parse_repeat("every_n_hours"), do: {:ok, :every_n_hours}
  defp parse_repeat("every_n_minutes"), do: {:ok, :every_n_minutes}
  defp parse_repeat(other), do: {:error, "invalid repeat: #{inspect(other)}"}

  defp build_attrs(session_id, name, prompt, repeat, params) do
    seed = %ScheduledTask{
      repeat: repeat,
      schedule_time: params[:at] || "00:00",
      every_n: params[:every] || 1,
      next_run_at: parse_iso(params[:next_run_at])
    }

    %{
      name: name,
      session_id: session_id,
      prompt: prompt,
      repeat: repeat,
      schedule_time: seed.schedule_time,
      every_n: seed.every_n,
      max_delay_hours: params[:max_delay_hours] || 6,
      enabled: true,
      next_run_at: Schedule.compute_next_run_at(seed, DateTime.utc_now()),
      metadata: %{}
    }
  end

  defp parse_iso(nil), do: nil
  defp parse_iso(""), do: nil

  defp parse_iso(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
