defmodule Long.Agent.Bots.TelegramMultiBotTest do
  # async: false — shares the global Telegram.Manager/Registry; relies on
  # shared-mode sandbox so those processes see our rows. We deliberately
  # do NOT start live bot workers here (they'd long-poll api.telegram.org);
  # the start/stop reconciliation is an identical mirror of
  # `Long.Agent.Bots.Wechat.Manager`, covered by WechatMultiAccountTest.
  use Long.DataCase, async: false

  alias Long.Agent
  alias Long.Agent.Bots
  alias Long.Agent.Bots.Telegram.{Credential, Manager}

  describe "credential helpers" do
    test "enabled_names lists only enabled rows" do
      s = System.unique_integer([:positive])
      {:ok, _} = Agent.upsert_telegram_credential(%{name: "on-#{s}", bot_token: "t", enabled: true})
      {:ok, _} = Agent.upsert_telegram_credential(%{name: "off-#{s}", bot_token: "t", enabled: false})

      names = Credential.enabled_names()
      assert "on-#{s}" in names
      refute "off-#{s}" in names

      cleanup(["on-#{s}", "off-#{s}"])
    end

    test "load_named returns the named enabled bot, nil for disabled" do
      s = System.unique_integer([:positive])
      {:ok, _} = Agent.upsert_telegram_credential(%{name: "a-#{s}", bot_token: "tokA", enabled: true})
      {:ok, _} = Agent.upsert_telegram_credential(%{name: "b-#{s}", bot_token: "tokB", enabled: false})

      assert {"tokA", %{name: "a-" <> _}} = Credential.load_named("a-#{s}")
      assert Credential.load_named("b-#{s}") == nil

      cleanup(["a-#{s}", "b-#{s}"])
    end

    test "for_member resolves the bot assigned to a member" do
      {:ok, hh} = Agent.create_household(%{name: "H"})
      {:ok, m} = Agent.create_member(%{household_id: hh.id, display_name: "Kid", relation: :child})
      name = "bot-#{System.unique_integer([:positive])}"
      {:ok, _} = Agent.upsert_telegram_credential(%{name: name, bot_token: "t", member_id: m.id})

      assert Credential.for_member(m.id) == name
      assert Credential.for_member("00000000-0000-0000-0000-000000000000") == nil

      cleanup([name])
      Agent.destroy_household!(hh)
    end
  end

  describe "inbound binds the chat to the bot's member" do
    test "a dedicated bot's member_id is authoritative; an unassigned bot never clobbers it" do
      {:ok, hh} = Agent.create_household(%{name: "H"})
      {:ok, m1} = Agent.create_member(%{household_id: hh.id, display_name: "A", relation: :self})
      {:ok, m2} = Agent.create_member(%{household_id: hh.id, display_name: "B", relation: :spouse})
      uid = "tg-#{System.unique_integer([:positive])}"

      {:ok, %{bot_user: u1}} = Bots.ensure_session(:telegram, uid, member_id: m1.id)
      assert u1.member_id == m1.id

      {:ok, %{bot_user: u2}} = Bots.ensure_session(:telegram, uid, member_id: m2.id)
      assert u2.member_id == m2.id

      {:ok, %{bot_user: u3, session_id: sid}} = Bots.ensure_session(:telegram, uid, member_id: nil)
      assert u3.member_id == m2.id

      Agent.destroy_bot_user!(u3)
      Agent.destroy_session!(sid)
      Agent.destroy_household!(hh)
    end
  end

  describe "worker resolution" do
    test "worker_pid is nil when no worker runs for that name" do
      assert Manager.worker_pid("nope-#{System.unique_integer([:positive])}") == nil
    end
  end

  defp cleanup(names) do
    Enum.each(names, fn n ->
      case Agent.get_telegram_credential(n) do
        {:ok, row} -> Agent.destroy_telegram_credential!(row)
        _ -> :ok
      end
    end)
  end
end
