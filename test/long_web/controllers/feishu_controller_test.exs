defmodule LongWeb.FeishuControllerTest do
  use LongWeb.ConnCase, async: false

  describe "POST /webhooks/feishu" do
    test "url_verification echoes the challenge", %{conn: conn} do
      conn =
        post(conn, ~p"/webhooks/feishu", %{
          "type" => "url_verification",
          "challenge" => "ch_42"
        })

      assert %{"challenge" => "ch_42"} = json_response(conn, 200)
    end

    test "non-message events are accepted with 200 ok (dev mode without token)", %{conn: conn} do
      payload = %{
        "header" => %{"event_type" => "irrelevant"},
        "event" => %{}
      }

      conn = post(conn, ~p"/webhooks/feishu", payload)
      assert %{"code" => 0} = json_response(conn, 200)
    end

    test "rejects bad signature when verification token is configured", %{conn: conn} do
      System.put_env("FEISHU_VERIFICATION_TOKEN", "secret")
      on_exit(fn -> System.delete_env("FEISHU_VERIFICATION_TOKEN") end)

      payload = %{"header" => %{"event_type" => "irrelevant"}, "event" => %{}}

      conn =
        conn
        |> put_req_header("x-lark-signature", "0000")
        |> put_req_header("x-lark-request-timestamp", "1")
        |> put_req_header("x-lark-request-nonce", "n")
        |> post(~p"/webhooks/feishu", payload)

      assert %{"code" => 1, "msg" => "bad signature"} = json_response(conn, 401)
    end
  end
end
