defmodule Long.Agent.Bots.WechatMultiAccountTest do
  # async: false — touches the globally-running Wechat.Manager + Registry,
  # and relies on shared-mode sandbox so those processes see our rows.
  use Long.DataCase, async: false

  alias Long.Agent
  alias Long.Agent.Bots
  alias Long.Agent.Bots.Wechat
  alias Long.Agent.Bots.Wechat.{Credential, Manager}

  @registry Long.Agent.Bots.Wechat.Registry

  defp running_names, do: Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met in time")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  describe "Manager reconciliation" do
    test "runs one worker per credential and stops it when the credential is deleted" do
      n1 = "test-acct-#{System.unique_integer([:positive])}"
      n2 = "test-acct-#{System.unique_integer([:positive])}"

      # No bot_token → workers register but stay idle (no iLink polling).
      {:ok, _} = Agent.upsert_wechat_credential(%{name: n1})
      {:ok, _} = Agent.upsert_wechat_credential(%{name: n2})

      Manager.reconcile()
      wait_until(fn -> n1 in running_names() and n2 in running_names() end)

      {:ok, row1} = Agent.get_wechat_credential(n1)
      Agent.destroy_wechat_credential!(row1)
      Manager.reconcile()
      wait_until(fn -> n1 not in running_names() and n2 in running_names() end)

      {:ok, row2} = Agent.get_wechat_credential(n2)
      Agent.destroy_wechat_credential!(row2)
      Manager.reconcile()
      wait_until(fn -> n2 not in running_names() end)
    end
  end

  describe "inbound binds a chat to the account's member" do
    test "a dedicated account's member_id is authoritative; an unassigned account never clobbers it" do
      {:ok, hh} = Agent.create_household(%{name: "H"})
      {:ok, m1} = Agent.create_member(%{household_id: hh.id, display_name: "A", relation: :self})
      {:ok, m2} = Agent.create_member(%{household_id: hh.id, display_name: "B", relation: :spouse})
      ext = "wx-#{System.unique_integer([:positive])}"

      {:ok, %{bot_user: u1}} = Bots.ensure_session(:wechat, ext, member_id: m1.id)
      assert u1.member_id == m1.id

      # Account reassigned to m2 → the next message updates the binding.
      {:ok, %{bot_user: u2}} = Bots.ensure_session(:wechat, ext, member_id: m2.id)
      assert u2.member_id == m2.id

      # An unassigned account (member_id nil) must NOT wipe the binding.
      {:ok, %{bot_user: u3, session_id: sid}} = Bots.ensure_session(:wechat, ext, member_id: nil)
      assert u3.member_id == m2.id

      Agent.destroy_bot_user!(u3)
      Agent.destroy_session!(sid)
      Agent.destroy_household!(hh)
    end

    test "records and updates the chat's credential_name (channel), without clobbering on nil" do
      ext = "wx-cred-#{System.unique_integer([:positive])}"

      {:ok, %{bot_user: u1}} = Bots.ensure_session(:wechat, ext, credential_name: "acctA")
      assert u1.credential_name == "acctA"

      # the chat moved/relogged onto another account → updates
      {:ok, %{bot_user: u2}} = Bots.ensure_session(:wechat, ext, credential_name: "acctB")
      assert u2.credential_name == "acctB"

      # a call without a credential_name must not wipe it
      {:ok, %{bot_user: u3, session_id: sid}} = Bots.ensure_session(:wechat, ext, credential_name: nil)
      assert u3.credential_name == "acctB"

      Agent.destroy_bot_user!(u3)
      Agent.destroy_session!(sid)
    end
  end

  describe "outbound routing per account" do
    test "for_member resolves the account assigned to a member" do
      {:ok, hh} = Agent.create_household(%{name: "H"})
      {:ok, m} = Agent.create_member(%{household_id: hh.id, display_name: "Dad", relation: :parent})
      name = "acct-#{System.unique_integer([:positive])}"
      {:ok, _} = Agent.upsert_wechat_credential(%{name: name, member_id: m.id})

      assert Credential.for_member(m.id) == name
      assert Credential.for_member("00000000-0000-0000-0000-000000000000") == nil

      {:ok, row} = Agent.get_wechat_credential(name)
      Agent.destroy_wechat_credential!(row)
      Manager.reconcile()
      Agent.destroy_household!(hh)
    end

    test "push to an account with no token errors instead of sending" do
      name = "acct-#{System.unique_integer([:positive])}"
      {:ok, _} = Agent.upsert_wechat_credential(%{name: name})

      assert {:error, :no_credential} =
               Wechat.push("some-openid", %{text: "hi"}, credential_name: name)

      {:ok, row} = Agent.get_wechat_credential(name)
      Agent.destroy_wechat_credential!(row)
      Manager.reconcile()
    end
  end
end
