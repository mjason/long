defmodule Long.Agent.Schedule do
  @moduledoc """
  Pure helpers for computing the next-run timestamp on a scheduled task and
  deciding whether a task is currently due. Kept separate from the Ash
  resource and the Oban workers so the policy is easy to unit-test.
  """

  alias Long.Agent.ScheduledTask

  @doc """
  Given a task and the current UTC time, returns the next `DateTime` at
  which the task should fire. For `:once` tasks the return is whatever was
  already on `:next_run_at`, or `now` if absent — the worker is expected to
  disable the task after the first run.
  """
  def compute_next_run_at(%ScheduledTask{repeat: :once, next_run_at: nrr}, now) do
    nrr || now
  end

  def compute_next_run_at(%ScheduledTask{repeat: :daily, schedule_time: ts}, now) do
    advance_to_time_of_day(now, parse_hhmm(ts), 1)
  end

  def compute_next_run_at(%ScheduledTask{repeat: :weekday, schedule_time: ts}, now) do
    skip_weekend(advance_to_time_of_day(now, parse_hhmm(ts), 1))
  end

  def compute_next_run_at(%ScheduledTask{repeat: :weekly, schedule_time: ts}, now) do
    advance_to_time_of_day(now, parse_hhmm(ts), 7)
  end

  def compute_next_run_at(%ScheduledTask{repeat: :monthly, schedule_time: ts}, now) do
    {h, m} = parse_hhmm(ts)

    %{now | hour: h, minute: m, second: 0, microsecond: {0, 0}}
    |> add_months(1)
  end

  def compute_next_run_at(%ScheduledTask{repeat: :every_n_hours, every_n: n}, now)
      when is_integer(n) and n > 0 do
    DateTime.add(now, n * 3600, :second)
  end

  def compute_next_run_at(%ScheduledTask{repeat: :every_n_minutes, every_n: n}, now)
      when is_integer(n) and n > 0 do
    DateTime.add(now, n * 60, :second)
  end

  @doc """
  Returns `true` if the task should run right now: it's enabled, its
  `next_run_at` (or fallback) has passed, and we're still inside the
  `max_delay_hours` window so we don't fire stale tasks after a long outage.
  """
  def due?(%ScheduledTask{enabled: false}, _now), do: false

  def due?(%ScheduledTask{} = task, now) do
    target = task.next_run_at || initial_target(task, now)

    cond do
      DateTime.compare(target, now) == :gt -> false
      stale?(target, now, task.max_delay_hours) -> false
      true -> true
    end
  end

  @doc """
  Static timezone context for the (cached) system prompt — the user's zone and
  the store-UTC rule. The zone changes rarely, so this is cache-safe. The
  current time deliberately does NOT live here (it changes every turn and would
  bust the prompt cache); it rides the user turn via `now_line/1`.
  """
  def timezone_note do
    "The user's timezone is #{Long.Agent.user_timezone()}. Times stored on a " <>
      "scheduled task (scheduleTime / nextRunAt) MUST be UTC — convert the " <>
      "user's stated local time to UTC first."
  end

  @doc """
  The current time (UTC + the user's local zone) for the *current* user turn.
  Kept off the system prompt so it never busts the prompt cache — it's prepended
  to the latest user message instead, and isn't persisted into history.
  """
  def now_line(now \\ DateTime.utc_now()) do
    tz = Long.Agent.user_timezone()
    utc = DateTime.truncate(now, :second)

    case DateTime.shift_zone(utc, tz) do
      {:ok, local} ->
        "[Current time: #{DateTime.to_iso8601(utc)} UTC = " <>
          "#{Calendar.strftime(local, "%Y-%m-%d %H:%M %A")} #{tz}]"

      _ ->
        "[Current time: #{DateTime.to_iso8601(utc)} UTC]"
    end
  end

  defp initial_target(%ScheduledTask{repeat: r, schedule_time: ts}, now)
       when r in [:daily, :weekday, :weekly, :monthly] do
    {h, m} = parse_hhmm(ts)
    %{now | hour: h, minute: m, second: 0, microsecond: {0, 0}}
  end

  defp initial_target(_task, now), do: now

  defp stale?(target, now, max_hours) when is_integer(max_hours) and max_hours > 0 do
    DateTime.diff(now, target, :second) > max_hours * 3600
  end

  defp stale?(_target, _now, _), do: false

  @doc ~s|Format an hour/minute pair as a zero-padded UTC "HH:MM" — the inverse of the internal `parse_hhmm/1`.|
  def format_hhmm(hour, minute)
      when is_integer(hour) and hour in 0..23 and is_integer(minute) and minute in 0..59 do
    :io_lib.format("~2..0B:~2..0B", [hour, minute]) |> IO.iodata_to_binary()
  end

  defp parse_hhmm(s) when is_binary(s) do
    case String.split(s, ":") do
      [h, m] ->
        case {Integer.parse(h), Integer.parse(m)} do
          {{hh, ""}, {mm, ""}} when hh in 0..23 and mm in 0..59 -> {hh, mm}
          _ -> {0, 0}
        end

      _ ->
        {0, 0}
    end
  end

  defp parse_hhmm(_), do: {0, 0}

  defp advance_to_time_of_day(now, {h, m}, default_step_days) do
    target = %{now | hour: h, minute: m, second: 0, microsecond: {0, 0}}

    if DateTime.compare(target, now) == :gt do
      target
    else
      DateTime.add(target, default_step_days * 86_400, :second)
    end
  end

  defp skip_weekend(%DateTime{} = dt) do
    case Date.day_of_week(DateTime.to_date(dt)) do
      d when d in 1..5 -> dt
      6 -> DateTime.add(dt, 2 * 86_400, :second)
      7 -> DateTime.add(dt, 1 * 86_400, :second)
    end
  end

  defp add_months(%DateTime{year: y, month: m, day: d} = dt, n) do
    total = m + n
    new_year = y + div(total - 1, 12)
    new_month = rem(total - 1, 12) + 1
    last_day = :calendar.last_day_of_the_month(new_year, new_month)
    %{dt | year: new_year, month: new_month, day: min(d, last_day)}
  end
end
