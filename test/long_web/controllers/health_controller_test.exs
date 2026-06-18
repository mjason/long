defmodule LongWeb.HealthControllerTest do
  use LongWeb.ConnCase, async: false

  alias Long.Heartbeat

  test "GET /healthz returns 200 ok when every loop is fresh", %{conn: conn} do
    Heartbeat.beat(:scheduler)
    conn = get(conn, "/healthz")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "ok"
    assert Enum.any?(body["sources"], &(&1["source"] == ":scheduler"))
  end

  test "GET /healthz returns 503 degraded when a loop is stale", %{conn: conn} do
    # An isolated stale probe (10 min old, past every threshold). Cleaned up so
    # it can't linger and trip the "ok" test under random ordering.
    src = :healthz_stale_probe
    :ets.insert(Heartbeat, {src, System.monotonic_time(:millisecond) - :timer.minutes(10)})
    on_exit(fn -> :ets.delete(Heartbeat, src) end)

    conn = get(conn, "/healthz")
    assert conn.status == 503
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "degraded"
    probe = Enum.find(body["sources"], &(&1["source"] == inspect(src)))
    assert probe["stale"] == true
  end
end
