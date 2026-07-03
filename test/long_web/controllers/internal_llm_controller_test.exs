defmodule LongWeb.InternalLLMControllerTest do
  use LongWeb.ConnCase, async: true

  alias Long.Agent.LLMBridge

  defp json_conn(conn), do: put_req_header(conn, "accept", "application/json")

  test "rejects a request with no token → 401", %{conn: conn} do
    conn = conn |> json_conn() |> post("/internal/llm", %{"prompt" => "hi"})
    assert json_response(conn, 401)["error"]
  end

  test "rejects a garbage token → 401", %{conn: conn} do
    conn =
      conn
      |> json_conn()
      |> put_req_header("x-llm-token", "nope")
      |> post("/internal/llm", %{"prompt" => "hi"})

    assert json_response(conn, 401)["error"]
  end

  test "a valid token with an empty body → 400 (auth passed, nothing to do)", %{conn: conn} do
    token = LLMBridge.sign("sess-abc")

    conn =
      conn
      |> json_conn()
      |> put_req_header("x-llm-token", token)
      |> post("/internal/llm", %{})

    assert json_response(conn, 400)["error"]
  end
end
