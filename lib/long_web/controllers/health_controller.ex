defmodule LongWeb.HealthController do
  @moduledoc """
  `GET /healthz` — liveness of the background loops, derived from `Long.Heartbeat`.

  Returns `200 {"status":"ok",…}` when every loop that has ever beaten is fresh,
  or `503 {"status":"degraded",…}` listing the stale ones. This is what turns a
  silently-hung loop (alive process, no work — invisible to OTP supervision) into
  something an external monitor can see in minutes. Point a uptime check at it.

  A loop is only judged once it has beaten at least once, so an unconfigured bot
  (never beats) never trips the check; the scheduler appears within one tick of boot.
  """

  use LongWeb, :controller

  alias Long.Heartbeat

  # Per-source staleness thresholds. Scheduler ticks each minute; bots long-poll
  # continuously. Generous enough to ride out one slow cycle / a host GC pause.
  @scheduler_stale_ms :timer.minutes(3)
  @default_stale_ms :timer.minutes(2)

  def show(conn, _params) do
    now = System.monotonic_time(:millisecond)

    sources =
      Enum.map(Heartbeat.all(), fn {source, ms} ->
        age = now - ms
        %{source: inspect(source), age_ms: age, stale: age > threshold(source)}
      end)

    {status, code} =
      if Enum.any?(sources, & &1.stale), do: {"degraded", 503}, else: {"ok", 200}

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(code, Jason.encode!(%{status: status, sources: sources}))
  end

  defp threshold(:scheduler), do: @scheduler_stale_ms
  defp threshold(_), do: @default_stale_ms
end
