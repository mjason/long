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

  describe "2-person group — any target reaches the one other member (any language)" do
    setup do
      {:ok, sid: setup_group([{"太子", :self, true}])}
    end

    test "a pronoun in any language reaches them", %{sid: sid} do
      assert {:ok, %{to: "太子", channels: 1}} = run("他", sid)
      assert {:ok, %{to: "太子"}} = run("him", sid)
      assert {:ok, %{to: "太子"}} = run("对方", sid)
    end

    test "an empty / nil target reaches them", %{sid: sid} do
      assert {:ok, %{to: "太子"}} = run("", sid)
      assert {:ok, %{to: "太子"}} = run(nil, sid)
    end

    test "a name or even a non-matching word still reaches the only other member", %{sid: sid} do
      assert {:ok, %{to: "太子"}} = run("太子", sid)
      assert {:ok, %{to: "太子"}} = run("neighbour bob", sid)
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
end
