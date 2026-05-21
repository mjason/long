defmodule Long.Agent.TelegramCredentialTest do
  use Long.DataCase, async: false

  alias Long.Agent
  alias Long.Agent.Bots.Telegram.Credential

  setup do
    System.delete_env("TELEGRAM_BOT_TOKEN")

    on_exit(fn ->
      System.delete_env("TELEGRAM_BOT_TOKEN")
    end)

    :ok
  end

  describe "upsert_telegram_credential/1" do
    test "creates a new credential" do
      assert {:ok, row} =
               Agent.upsert_telegram_credential(%{
                 name: "default",
                 bot_token: "123:ABC",
                 enabled: true
               })

      assert row.name == "default"
      assert row.bot_token == "123:ABC"
      assert row.enabled == true
    end

    test "upserts on duplicate name" do
      {:ok, _} = Agent.upsert_telegram_credential(%{name: "default", bot_token: "v1"})

      {:ok, updated} =
        Agent.upsert_telegram_credential(%{
          name: "default",
          bot_token: "v2",
          username: "my_bot"
        })

      assert updated.bot_token == "v2"
      assert updated.username == "my_bot"
      assert {:ok, [_]} = Agent.list_telegram_credentials()
    end
  end

  describe "Credential.load/0 precedence" do
    test "returns DB row when enabled (regardless of name)" do
      {:ok, _} =
        Agent.upsert_telegram_credential(%{name: "电报", bot_token: "from-db", enabled: true})

      assert {"from-db", %{name: "电报"}} = Credential.load()
    end

    test "skips disabled row and falls back to env" do
      {:ok, _} =
        Agent.upsert_telegram_credential(%{name: "default", bot_token: "from-db", enabled: false})

      System.put_env("TELEGRAM_BOT_TOKEN", "from-env")

      assert {"from-env", nil} = Credential.load()
    end

    test "returns nil when no credential and no env" do
      assert Credential.load() == nil
    end

    test "env-only path returns {token, nil}" do
      System.put_env("TELEGRAM_BOT_TOKEN", "env-token")
      assert {"env-token", nil} = Credential.load()
    end

    test "DB row beats env when both set" do
      {:ok, _} =
        Agent.upsert_telegram_credential(%{name: "default", bot_token: "from-db", enabled: true})

      System.put_env("TELEGRAM_BOT_TOKEN", "from-env")

      assert {"from-db", _} = Credential.load()
    end

    test "picks first enabled row by name when multiple exist" do
      {:ok, _} =
        Agent.upsert_telegram_credential(%{name: "z-second", bot_token: "second", enabled: true})

      {:ok, _} =
        Agent.upsert_telegram_credential(%{name: "a-first", bot_token: "first", enabled: true})

      assert {"first", %{name: "a-first"}} = Credential.load()
    end
  end

  describe "Credential.save_username/2" do
    test "writes the username back to the row" do
      {:ok, row} =
        Agent.upsert_telegram_credential(%{name: "default", bot_token: "tok", enabled: true})

      assert :ok = Credential.save_username(row, "my_long_bot")

      {:ok, reloaded} = Agent.get_telegram_credential("default")
      assert reloaded.username == "my_long_bot"
    end

    test "skips DB write when username is unchanged" do
      {:ok, row} =
        Agent.upsert_telegram_credential(%{
          name: "default",
          bot_token: "tok",
          username: "same",
          enabled: true
        })

      # Same-username path is matched in the function head, so the DB
      # row's updated_at must be unchanged after the call.
      assert :ok = Credential.save_username(row, "same")
      {:ok, reloaded} = Agent.get_telegram_credential("default")
      assert reloaded.updated_at == row.updated_at
    end

    test "no-op for nil row (env-only path)" do
      assert :ok = Credential.save_username(nil, "anything")
    end
  end

  describe "destroy_telegram_credential/1" do
    test "removes the row" do
      {:ok, row} =
        Agent.upsert_telegram_credential(%{name: "default", bot_token: "tok", enabled: true})

      assert :ok = Agent.destroy_telegram_credential(row)
      assert {:error, _} = Agent.get_telegram_credential("default")
    end
  end
end
