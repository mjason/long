defmodule Long.Jido.Tools.NotifyMemberTest do
  # async: false — delivery touches the globally-running bot workers via
  # Outbound, and relies on shared-mode sandbox.
  use Long.DataCase, async: false

  alias Long.Agent
  alias Long.Jido.Tools.NotifyMember

  # Caller is "爱人" (the owner); `others` is a list of {name, relation, bound?}.
  defp setup_group(others) do
    {:ok, hh} = Agent.create_group(%{name: "Fam-#{uniq()}"})

    {:ok, caller} =
      Agent.create_member(%{group_id: hh.id, display_name: "爱人", relation: :other, role: :owner})

    sess = Agent.start_session!(%{title: "t"})

    {:ok, _} =
      Agent.create_bot_user(%{
        platform: :wechat,
        external_id: "caller-#{uniq()}",
        session_id: sess.id,
        member_id: caller.id
      })

    for {name, rel, bound?} <- others do
      {:ok, m} = Agent.create_member(%{group_id: hh.id, display_name: name, relation: rel})

      if bound? do
        {:ok, _} =
          Agent.create_bot_user(%{
            platform: :telegram,
            external_id: "o-#{uniq()}",
            chat_id: "1",
            member_id: m.id
          })
      end
    end

    sess.id
  end

  defp uniq, do: System.unique_integer([:positive])
  defp run(target, sid), do: NotifyMember.run(%{target: target, message: "好的"}, %{session_id: sid})

  describe "2-person group — empty target auto-routes; a named target must still match" do
    setup do
      {:ok, sid: setup_group([{"太子", :self, true}])}
    end

    test "an empty / nil target reaches the one other member", %{sid: sid} do
      assert {:ok, %{to: "太子", channels: 1}} = run("", sid)
      assert {:ok, %{to: "太子"}} = run(nil, sid)
    end

    test "the other member's name (even partial) reaches them", %{sid: sid} do
      assert {:ok, %{to: "太子"}} = run("太子", sid)
      assert {:ok, %{to: "太子"}} = run("太", sid)
    end

    # Regression: naming someone who isn't the one other member — the caller
    # themselves, a pronoun, or any non-matching word — must NOT be force-
    # delivered to that member (the bug where notifying the caller reached
    # the only other member instead). The error lists who's available so the
    # LLM retries with a real name or an empty target.
    test "a non-matching name errors with the roster, never mis-delivers", %{sid: sid} do
      assert {:ok, %{status: "error", msg: msg}} = run("大人", sid)
      assert msg =~ "太子"
      assert {:ok, %{status: "error"}} = run("neighbour bob", sid)
      assert {:ok, %{status: "error"}} = run("他", sid)
    end
  end

  describe "several other members — needs a specific match, English diagnostics" do
    test "a display name resolves uniquely" do
      sid = setup_group([{"太子", :other, true}, {"奶奶", :other, true}])
      assert {:ok, %{to: "奶奶"}} = run("奶奶", sid)
    end

    test "a partial display name resolves uniquely" do
      sid = setup_group([{"Alice", :other, true}, {"Bob", :other, true}])
      assert {:ok, %{to: "Alice"}} = run("ali", sid)
    end

    test "an ambiguous partial name lists the candidates" do
      sid = setup_group([{"Alice", :other, true}, {"Alicia", :other, true}])
      assert {:ok, %{status: "error", msg: msg}} = run("ali", sid)
      assert msg =~ "Alice" and msg =~ "Alicia"
    end

    test "an unknown target lists who's available" do
      sid = setup_group([{"Alice", :other, true}, {"Bob", :other, true}])
      assert {:ok, %{status: "error", msg: msg}} = run("Zoe", sid)
      assert msg =~ "Alice" and msg =~ "Bob"
    end

    test "an empty target asks which member" do
      sid = setup_group([{"Alice", :other, true}, {"Bob", :other, true}])
      assert {:ok, %{status: "error", msg: msg}} = run("", sid)
      assert msg =~ "which member"
    end
  end

  describe "edge cases" do
    test "errors when the caller is the only member" do
      sid = setup_group([])
      assert {:ok, %{status: "error", msg: msg}} = run("他", sid)
      assert msg =~ "only member"
    end

    test "errors when the target has no bound channel" do
      sid = setup_group([{"太子", :self, false}])
      assert {:ok, %{status: "error", msg: msg}} = run("太子", sid)
      assert msg =~ "no linked chat account"
    end

    test "errors when the chat isn't bound to a member" do
      sess = Agent.start_session!(%{title: "web"})
      assert {:ok, %{status: "error", msg: msg}} = run("他", sess.id)
      assert msg =~ "/bind"
    end

    # Regression (privilege escalation): a bot account that exists but never
    # /bind-ed is a stranger — it must be rejected, NOT silently promoted to
    # the owner. Before the fix this fell back to default_member and notified
    # the group as the owner.
    test "an unbound bot account can't notify even when an owner exists" do
      {:ok, hh} = Agent.create_group(%{name: "Esc-#{uniq()}"})

      {:ok, _owner} =
        Agent.create_member(%{group_id: hh.id, display_name: "Owner", relation: :self, role: :owner})

      {:ok, _queen} =
        Agent.create_member(%{group_id: hh.id, display_name: "Queen", relation: :other})

      sess = Agent.start_session!(%{title: "telegram:stranger"})

      {:ok, _} =
        Agent.create_bot_user(%{
          platform: :telegram,
          external_id: "stranger-#{uniq()}",
          chat_id: "999",
          session_id: sess.id,
          member_id: nil
        })

      assert {:ok, %{status: "error", msg: msg}} = run("Queen", sess.id)
      assert msg =~ "/bind"
    end

    # The flip side: a web /chat session has NO bot account, so it legitimately
    # acts as the owner — that must keep working.
    test "a web /chat session (no bot account) still acts as the owner" do
      {:ok, hh} = Agent.create_group(%{name: "Web-#{uniq()}"})

      {:ok, _owner} =
        Agent.create_member(%{group_id: hh.id, display_name: "Owner", relation: :self, role: :owner})

      {:ok, queen} =
        Agent.create_member(%{group_id: hh.id, display_name: "Queen", relation: :other})

      {:ok, _} =
        Agent.create_bot_user(%{
          platform: :telegram,
          external_id: "q-#{uniq()}",
          chat_id: "1",
          member_id: queen.id
        })

      sess = Agent.start_session!(%{title: "web"})
      me = self()
      deliver = fn _bu, _body -> send(me, :pushed) && :ok end

      assert {:ok, %{status: "sent", to: "Queen"}} =
               NotifyMember.run(%{target: "Queen", message: "hi"}, %{session_id: sess.id, deliver: deliver})
    end
  end

  describe "delivery (injectable — no live worker needed)" do
    setup do
      {:ok, hh} = Agent.create_group(%{name: "D-#{uniq()}"})

      {:ok, _caller} =
        Agent.create_member(%{group_id: hh.id, display_name: "Me", relation: :self, role: :owner})

      {:ok, target} =
        Agent.create_member(%{group_id: hh.id, display_name: "Spouse", relation: :other})

      sess = Agent.start_session!(%{title: "t"})

      {:ok, _} =
        Agent.create_bot_user(%{
          platform: :wechat,
          external_id: "caller-#{uniq()}",
          session_id: sess.id,
          member_id: (Agent.list_members!() |> Enum.find(&(&1.relation == :self and &1.group_id == hh.id))).id
        })

      {:ok, sid: sess.id, target: target}
    end

    defp run_deliver(sid, deliver),
      do: NotifyMember.run(%{target: "spouse", message: "dinner at 6"}, %{session_id: sid, deliver: deliver})

    test "delivers to the exact channel the chat arrived on, with the composed message", %{sid: sid, target: target} do
      {:ok, _} =
        Agent.create_bot_user(%{
          platform: :telegram,
          external_id: "tg-#{uniq()}",
          chat_id: "555",
          member_id: target.id,
          credential_name: "电报"
        })

      me = self()
      deliver = fn bu, body -> send(me, {:pushed, bu, body}) && :ok end

      assert {:ok, %{status: "sent", delivered: 1, channels: 1}} = run_deliver(sid, deliver)

      assert_receive {:pushed, bu, body}
      assert bu.platform == :telegram and bu.chat_id == "555" and bu.credential_name == "电报"
      assert body.text =~ "dinner at 6"
    end

    test "counts only successful channels; partial success stays 'sent'", %{sid: sid, target: target} do
      for p <- [:telegram, :wechat] do
        {:ok, _} =
          Agent.create_bot_user(%{platform: p, external_id: "#{p}-#{uniq()}", chat_id: "1", member_id: target.id})
      end

      deliver = fn
        %{platform: :telegram}, _ -> :ok
        %{platform: :wechat}, _ -> {:error, :no_credential}
      end

      assert {:ok, %{status: "sent", channels: 2, delivered: 1}} = run_deliver(sid, deliver)
    end

    test "surfaces the failure reason when every channel fails", %{sid: sid, target: target} do
      {:ok, _} =
        Agent.create_bot_user(%{platform: :telegram, external_id: "tg-#{uniq()}", chat_id: "1", member_id: target.id})

      deliver = fn _bu, _body -> {:error, :telegram_worker_not_running} end

      assert {:ok, %{status: "error", delivered: 0, msg: msg}} = run_deliver(sid, deliver)
      assert msg =~ "telegram_worker_not_running"
      assert msg =~ "Spouse"
    end

    test "an exit/raise inside delivery is captured, not crashed", %{sid: sid, target: target} do
      {:ok, _} =
        Agent.create_bot_user(%{platform: :telegram, external_id: "tg-#{uniq()}", chat_id: "1", member_id: target.id})

      assert {:ok, %{status: "error", delivered: 0}} = run_deliver(sid, fn _, _ -> exit(:boom) end)
    end
  end

  # Regression: assigning a hosted account to a member via the admin path
  # must make that member reachable for notify *immediately* — not only after
  # the next inbound message lazily backfills the chat identity. The bug was
  # that `set_member` only set `credential.member_id` (inbound attribution),
  # leaving the account's `bot_user`s unbound, so outbound notify said the
  # member had "no linked chat account".
  describe "assigning a hosted account backfills its chat identities" do
    test "set_wechat_credential_member makes a previously-unreachable member reachable" do
      {:ok, hh} = Agent.create_group(%{name: "Assign-#{uniq()}"})

      {:ok, caller} =
        Agent.create_member(%{group_id: hh.id, display_name: "Me", relation: :self, role: :owner})

      {:ok, target} =
        Agent.create_member(%{group_id: hh.id, display_name: "Queen", relation: :other})

      sess = Agent.start_session!(%{title: "t"})

      {:ok, _} =
        Agent.create_bot_user(%{
          platform: :wechat,
          external_id: "caller-#{uniq()}",
          session_id: sess.id,
          member_id: caller.id
        })

      # A chat arrived on a hosted account but isn't bound to any member yet.
      name = "queen-acct-#{uniq()}"
      {:ok, _} = Agent.upsert_wechat_credential(%{name: name})

      {:ok, bu} =
        Agent.create_bot_user(%{
          platform: :wechat,
          external_id: "queen-#{uniq()}",
          chat_id: "1",
          credential_name: name,
          member_id: nil
        })

      # Before assignment the target has no channel — notify can't reach her.
      assert {:ok, %{status: "error", msg: msg}} =
               NotifyMember.run(%{target: "Queen", message: "rest"}, %{session_id: sess.id})

      assert msg =~ "no linked chat account"

      # Admin assigns the account to the member.
      {:ok, cred} = Agent.get_wechat_credential(name)
      {:ok, _} = Agent.set_wechat_credential_member(cred, %{member_id: target.id})

      # The account's chat identity now belongs to the member…
      {:ok, users} = Agent.list_bot_users()
      assert Enum.find(users, &(&1.id == bu.id)).member_id == target.id

      # …so notify reaches her, via that exact account.
      me = self()
      deliver = fn pushed, _body -> send(me, {:pushed, pushed}) && :ok end

      assert {:ok, %{status: "sent", to: "Queen", delivered: 1}} =
               NotifyMember.run(%{target: "Queen", message: "rest"}, %{session_id: sess.id, deliver: deliver})

      assert_receive {:pushed, pushed}
      assert pushed.credential_name == name
    end

    test "un-assigning (nil) keeps the existing binding — never clobbers a /bind" do
      {:ok, hh} = Agent.create_group(%{name: "Unassign-#{uniq()}"})
      {:ok, m} = Agent.create_member(%{group_id: hh.id, display_name: "X", relation: :other})

      name = "acct-#{uniq()}"
      {:ok, _} = Agent.upsert_wechat_credential(%{name: name, member_id: m.id})

      {:ok, bu} =
        Agent.create_bot_user(%{
          platform: :wechat,
          external_id: "u-#{uniq()}",
          credential_name: name,
          member_id: m.id
        })

      {:ok, cred} = Agent.get_wechat_credential(name)
      {:ok, _} = Agent.set_wechat_credential_member(cred, %{member_id: nil})

      {:ok, users} = Agent.list_bot_users()
      assert Enum.find(users, &(&1.id == bu.id)).member_id == m.id
    end

    test "backfill is scoped to the matching account + platform" do
      {:ok, hh} = Agent.create_group(%{name: "Scope-#{uniq()}"})
      {:ok, m} = Agent.create_member(%{group_id: hh.id, display_name: "Y", relation: :other})

      name = "acct-#{uniq()}"
      {:ok, _} = Agent.upsert_wechat_credential(%{name: name})

      {:ok, mine} =
        Agent.create_bot_user(%{platform: :wechat, external_id: "a-#{uniq()}", credential_name: name})

      # A chat on a *different* account must stay untouched.
      {:ok, foreign} =
        Agent.create_bot_user(%{
          platform: :wechat,
          external_id: "b-#{uniq()}",
          credential_name: "other-#{uniq()}"
        })

      {:ok, cred} = Agent.get_wechat_credential(name)
      {:ok, _} = Agent.set_wechat_credential_member(cred, %{member_id: m.id})

      {:ok, users} = Agent.list_bot_users()
      assert Enum.find(users, &(&1.id == mine.id)).member_id == m.id
      assert Enum.find(users, &(&1.id == foreign.id)).member_id == nil
    end

    test "set_telegram_credential_member backfills its bot_users too" do
      {:ok, hh} = Agent.create_group(%{name: "Tg-#{uniq()}"})
      {:ok, m} = Agent.create_member(%{group_id: hh.id, display_name: "Z", relation: :other})

      name = "tgacct-#{uniq()}"
      {:ok, _} = Agent.upsert_telegram_credential(%{name: name, bot_token: "t"})

      {:ok, bu} =
        Agent.create_bot_user(%{
          platform: :telegram,
          external_id: "tg-#{uniq()}",
          chat_id: "1",
          credential_name: name
        })

      {:ok, cred} = Agent.get_telegram_credential(name)
      {:ok, _} = Agent.set_telegram_credential_member(cred, %{member_id: m.id})

      {:ok, users} = Agent.list_bot_users()
      assert Enum.find(users, &(&1.id == bu.id)).member_id == m.id
    end
  end
end
