defmodule Long.Agent.BotsTest do
  use Long.DataCase, async: false

  import Long.AsyncHelpers, only: [eventually: 1]

  alias Long.Agent
  alias Long.Agent.Bots
  alias Long.Agent.Bots.{Feishu, Outbound, Telegram}

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

  describe "Bots.run_async/4 magic commands" do
    test "`/clear` wipes the session's messages + ack" do
      this = self()

      # Seed two messages on a session via the regular sync path
      {:ok, %{session_id: sid}} =
        Bots.ensure_session(:telegram, "clear-user", chat_id: "1")

      {:ok, _} = Bots.run_and_collect(:telegram, "clear-user", "hello", timeout: 5_000)

      {:ok, before} = Long.Agent.list_messages_for_session(sid)
      assert length(before) >= 2

      # Now fire /clear via run_async
      {:ok, %{mode: :cleared}} =
        Bots.run_async(:telegram, "clear-user", "/clear",
          on_complete: fn _user, result -> send(this, {:cleared_ack, result}) end
        )

      assert_receive {:cleared_ack, {:ok, %{text: text}}}, 1_000
      assert text =~ "已清空"

      # Wipe runs on a background task so the ack isn't blocked by DB
      # work; poll until the messages table is empty.
      eventually(fn ->
        {:ok, msgs} = Long.Agent.list_messages_for_session(sid)
        msgs == []
      end)
    end

    test "`/status` reports idle state when no agent is running" do
      this = self()

      {:ok, _} = Bots.ensure_session(:telegram, "status-user-idle", chat_id: "1")

      {:ok, %{mode: :status}} =
        Bots.run_async(:telegram, "status-user-idle", "/status",
          on_complete: fn _user, result -> send(this, {:status_ack, result}) end
        )

      assert_receive {:status_ack, {:ok, %{text: text}}}, 1_000
      assert text =~ "空闲"
    end

    test "`/status` reports owner + queue + btws when busy" do
      this = self()

      {:ok, %{session_id: sid}} =
        Bots.ensure_session(:telegram, "status-user-busy", chat_id: "1")

      # Simulate a held slot from another process so /status sees `running`
      owner =
        spawn(fn ->
          :acquired = Long.Agent.Activity.try_acquire_or_enqueue(sid, :held)
          Long.Agent.Activity.update(sid, %{turn: 3, tool: "web_scan"})
          send(this, :ready)
          receive do: (:release -> Long.Agent.Activity.release(sid))
        end)

      assert_receive :ready, 500
      :ok = Long.Agent.Activity.add_btw(sid, "note")

      {:ok, %{mode: :status}} =
        Bots.run_async(:telegram, "status-user-busy", "/status",
          on_complete: fn _user, result -> send(this, {:status_ack, result}) end
        )

      assert_receive {:status_ack, {:ok, %{text: text}}}, 1_000
      assert text =~ "运行中"
      assert text =~ "web_scan"
      assert text =~ "第 3 轮"
      assert text =~ "补充 1 条"

      send(owner, :release)
    end

    test "`/btw <note>` adds to btws + ack without spawning a new loop" do
      this = self()

      {:ok, %{session_id: sid}} =
        Bots.ensure_session(:telegram, "btw-user", chat_id: "1")

      # No active watcher — but /btw still acks (it's idempotent for
      # idle sessions; the next loop will pick up the note).
      {:ok, %{mode: :btw}} =
        Bots.run_async(:telegram, "btw-user", "/btw 注意要 PG-13",
          on_complete: fn _user, result -> send(this, {:btw_ack, result}) end
        )

      assert_receive {:btw_ack, {:ok, %{text: ack}}}, 1_000
      assert ack =~ "已经加入"

      assert ["注意要 PG-13"] = Long.Agent.Activity.take_btws(sid)
    end
  end

  describe "Agent.get_bot_user_for_session/1" do
    test "returns the BotUser tied to a session_id" do
      {:ok, %{bot_user: u, session_id: sid}} =
        Bots.ensure_session(:telegram, "lookup-1", chat_id: "100")

      assert {:ok, found} = Agent.get_bot_user_for_session(sid)
      assert found.id == u.id
      assert found.external_id == "lookup-1"
    end

    test "errors when no BotUser owns the session" do
      {:ok, sess} = Agent.start_session(%{title: "orphan"})
      assert {:error, _} = Agent.get_bot_user_for_session(sess.id)
    end
  end

  describe "Outbound.push/3 routing" do
    test "unsupported platform returns {:error, {:unsupported_platform, _}}" do
      assert {:error, {:unsupported_platform, :discord}} =
               Outbound.push(%{platform: :discord, external_id: "x"}, %{text: "hi"})
    end

    test "telegram with no chat_id/external_id returns :no_chat_id" do
      assert {:error, :no_chat_id} =
               Outbound.push(
                 %{platform: :telegram, chat_id: nil, external_id: nil},
                 %{text: "hi"}
               )

      assert {:error, :no_chat_id} =
               Outbound.push(
                 %{platform: :telegram, chat_id: "", external_id: ""},
                 %{text: "hi"}
               )
    end

    test "telegram falls back to external_id when chat_id is missing" do
      this = self()

      get_response = fn _opts ->
        {:ok, %Req.Response{status: 200, body: %{"ok" => true, "result" => []}}}
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
          name: :tg_outbound_test,
          token: "test-token",
          http: http,
          poll_interval_ms: 50,
          long_poll_timeout: 1
        )

      assert :ok =
               Outbound.push(
                 %{platform: :telegram, chat_id: nil, external_id: "42"},
                 %{text: "ping"},
                 server: :tg_outbound_test
               )

      assert_receive {:tg_send, opts}, 2_000
      body = Keyword.fetch!(opts, :json)
      assert body[:chat_id] == "42"
      assert body[:text] == "ping"

      GenServer.stop(pid)
    end

    test "wechat without external_id returns :no_uid" do
      assert {:error, :no_uid} =
               Outbound.push(%{platform: :wechat, external_id: nil}, %{text: "hi"})
    end

    test "feishu without external_id returns :no_open_id" do
      assert {:error, :no_open_id} =
               Outbound.push(%{platform: :feishu, external_id: nil}, %{text: "hi"})
    end
  end

  describe "Telegram.push/3" do
    test "skips empty bodies" do
      assert :ok = Telegram.push("1", %{text: "", ask: nil}, server: :nonexistent_server)
    end

    test "returns {:error, :telegram_worker_not_running} when server is down" do
      assert {:error, :telegram_worker_not_running} =
               Telegram.push("1", %{text: "hello"}, server: :nonexistent_server)
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

    test "send/3 posts to im/v1/messages with receive_id_type=open_id" do
      this = self()

      http = fn opts ->
        case Keyword.fetch!(opts, :url) do
          "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" ->
            {:ok,
             %Req.Response{
               status: 200,
               body: %{"code" => 0, "tenant_access_token" => "fake-token"}
             }}

          "https://open.feishu.cn/open-apis/im/v1/messages" ->
            send(this, {:feishu_send, opts})
            {:ok, %Req.Response{status: 200, body: %{"code" => 0}}}
        end
      end

      System.put_env("FEISHU_APP_ID", "id")
      System.put_env("FEISHU_APP_SECRET", "secret")

      on_exit(fn ->
        System.delete_env("FEISHU_APP_ID")
        System.delete_env("FEISHU_APP_SECRET")
      end)

      assert {:ok, :sent} = Feishu.send("ou_test", "hello from scheduler", http: http)
      assert_received {:feishu_send, opts}
      assert opts[:params] == %{receive_id_type: "open_id"}
      body = Keyword.fetch!(opts, :json)
      assert body["receive_id"] == "ou_test"
      assert body["msg_type"] == "text"
      assert {:ok, %{"text" => "hello from scheduler"}} = Jason.decode(body["content"])
    end

    test "push/3 delegates to send with the user's open_id" do
      this = self()

      http = fn opts ->
        case Keyword.fetch!(opts, :url) do
          "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" ->
            {:ok,
             %Req.Response{
               status: 200,
               body: %{"code" => 0, "tenant_access_token" => "fake-token"}
             }}

          "https://open.feishu.cn/open-apis/im/v1/messages" ->
            send(this, {:feishu_send, opts})
            {:ok, %Req.Response{status: 200, body: %{"code" => 0}}}
        end
      end

      System.put_env("FEISHU_APP_ID", "id")
      System.put_env("FEISHU_APP_SECRET", "secret")

      on_exit(fn ->
        System.delete_env("FEISHU_APP_ID")
        System.delete_env("FEISHU_APP_SECRET")
      end)

      assert :ok = Feishu.push("ou_test", %{text: "reminder", ask: nil}, http: http)
      assert_received {:feishu_send, _}
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

      assert {:ok, :accepted} = Feishu.handle_event(payload, http: http, timeout: 5_000)

      # Reply is dispatched asynchronously by the watcher task spawned
      # under Bots.run_async — wait for it to fire.
      assert_receive {:feishu_reply, _}, 5_000
    end
  end
end
