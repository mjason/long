defmodule Long.Agent.BotsTest do
  use Long.DataCase, async: false

  alias Long.Agent
  alias Long.Agent.Bots
  alias Long.Agent.Bots.{Feishu, Telegram}

  describe "BotUser CRUD" do
    test "create + lookup by (platform, external_id) identity" do
      {:ok, sess} = Agent.start_session(%{title: "u1"})

      {:ok, u} =
        Agent.create_bot_user(%{
          platform: :telegram,
          external_id: "12345",
          chat_id: "12345",
          display_name: "User One",
          session_id: sess.id
        })

      assert u.platform == :telegram

      # second create with same (platform, external_id) should violate identity
      assert {:error, _} =
               Agent.create_bot_user(%{
                 platform: :telegram,
                 external_id: "12345",
                 session_id: sess.id
               })
    end
  end

  describe "Bots.ensure_session/3" do
    test "creates a BotUser + session on first contact" do
      assert {:ok, %{session_id: sid, bot_user: user}} =
               Bots.ensure_session(:telegram, "u100",
                 chat_id: "u100",
                 display_name: "Alice"
               )

      assert user.platform == :telegram
      assert user.session_id == sid

      {:ok, sess} = Agent.get_session(sid)
      assert sess.title == "telegram:u100"
    end

    test "reuses an existing BotUser and refreshes metadata" do
      {:ok, %{session_id: sid1}} =
        Bots.ensure_session(:telegram, "u200", display_name: "Alice")

      assert {:ok, %{session_id: ^sid1, bot_user: user}} =
               Bots.ensure_session(:telegram, "u200", display_name: "Alice Refreshed")

      assert user.display_name == "Alice Refreshed"
    end
  end

  describe "Bots.run_and_collect/4" do
    test "drives Echo backend end-to-end and returns accumulated text" do
      assert {:ok, %{text: text, tool_calls: [], ask: nil}} =
               Bots.run_and_collect(:telegram, "echo-user-1", "ping",
                 chat_id: "echo-user-1",
                 timeout: 5_000
               )

      assert text =~ "(echo) ping"
    end

    test "passes through opts to the run (chat_id refreshes BotUser row)" do
      {:ok, _} =
        Bots.run_and_collect(:telegram, "stream-user", "hi", chat_id: "12345", timeout: 5_000)

      {:ok, all} = Long.Agent.list_bot_users()
      user = Enum.find(all, &(&1.external_id == "stream-user"))
      assert user.chat_id == "12345"
    end
  end

  describe "Telegram.extract_message/1" do
    test "pulls chat/user/text from a normal text update" do
      update = %{
        "update_id" => 42,
        "message" => %{
          "chat" => %{"id" => 9001},
          "from" => %{"id" => 100, "first_name" => "Foo", "last_name" => "Bar"},
          "text" => "hello"
        }
      }

      assert %{
               chat_id: "9001",
               user_id: "100",
               text: "hello",
               display_name: "Foo Bar"
             } = Telegram.extract_message(update)
    end

    test "returns nil for non-message updates" do
      assert Telegram.extract_message(%{"update_id" => 1, "callback_query" => %{}}) == nil
      assert Telegram.extract_message(%{"message" => %{}}) == nil
    end
  end

  describe "Telegram GenServer" do
    test "start_link returns :ignore when no token is configured" do
      System.delete_env("TELEGRAM_BOT_TOKEN")
      assert :ignore = Telegram.start_link([])
    end

    test "polls, dispatches messages, and sends a reply back via injected http" do
      this = self()

      get_response = fn _opts ->
        first_call? =
          if :erlang.get(:tg_called) == true do
            false
          else
            :erlang.put(:tg_called, true)
            true
          end

        if first_call? do
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "ok" => true,
               "result" => [
                 %{
                   "update_id" => 1,
                   "message" => %{
                     "chat" => %{"id" => 7},
                     "from" => %{"id" => 7, "first_name" => "Tester"},
                     "text" => "ping"
                   }
                 }
               ]
             }
           }}
        else
          {:ok, %Req.Response{status: 200, body: %{"ok" => true, "result" => []}}}
        end
      end

      http = fn opts ->
        case Keyword.fetch!(opts, :method) do
          :get ->
            get_response.(opts)

          :post ->
            send(this, {:tg_send, opts})
            {:ok, %Req.Response{status: 200, body: %{"ok" => true, "result" => %{}}}}
        end
      end

      {:ok, pid} =
        Telegram.start_link(
          name: :tg_test_bot,
          token: "test-token",
          http: http,
          poll_interval_ms: 10,
          long_poll_timeout: 1
        )

      # Allow the spawned Task to use the DB sandbox
      Ecto.Adapters.SQL.Sandbox.allow(Long.Repo, this, pid)

      assert_receive {:tg_send, opts}, 5_000

      body = Keyword.fetch!(opts, :json)
      assert body[:chat_id] == "7"
      assert body[:text] =~ "(echo) ping"

      GenServer.stop(pid)
    end
  end

  describe "Feishu" do
    test "handle_verification echoes the challenge" do
      assert %{"challenge" => "abc123"} = Feishu.handle_verification(%{"challenge" => "abc123"})
    end

    test "handle_event ignores non-message events" do
      assert {:ok, :ignored} = Feishu.handle_event(%{"header" => %{"event_type" => "other"}})
      assert {:ok, :ignored} = Feishu.handle_event(%{})
    end

    test "handle_event drives the loop, calls reply with rendered text" do
      this = self()

      http = fn opts ->
        case Keyword.fetch!(opts, :url) do
          "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" ->
            {:ok,
             %Req.Response{
               status: 200,
               body: %{"code" => 0, "tenant_access_token" => "fake-token"}
             }}

          "https://open.feishu.cn/open-apis/im/v1/messages/m_42/reply" ->
            send(this, {:feishu_reply, opts})
            {:ok, %Req.Response{status: 200, body: %{"code" => 0}}}
        end
      end

      System.put_env("FEISHU_APP_ID", "id")
      System.put_env("FEISHU_APP_SECRET", "secret")

      on_exit(fn ->
        System.delete_env("FEISHU_APP_ID")
        System.delete_env("FEISHU_APP_SECRET")
      end)

      payload = %{
        "header" => %{"event_type" => "im.message.receive_v1"},
        "event" => %{
          "sender" => %{"sender_id" => %{"open_id" => "ou_99", "user_id" => "Bob"}},
          "message" => %{
            "chat_id" => "oc_1",
            "message_id" => "m_42",
            "content" => Jason.encode!(%{"text" => "hello feishu"})
          }
        }
      }

      assert {:ok, :replied} = Feishu.handle_event(payload, http: http, timeout: 5_000)
      assert_received {:feishu_reply, _}
    end
  end
end
