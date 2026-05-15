defmodule Long.Agent.Memory.RecallTest do
  use Long.DataCase, async: false

  alias Long.Agent
  alias Long.Agent.Memory.Recall

  setup do
    {:ok, session} = Agent.start_session(%{title: "recall-test"})
    {:ok, session: session}
  end

  describe "recall/2" do
    test "returns matching session + global memories ranked by score", %{session: session} do
      {:ok, _} =
        Agent.put_session_memory(%{
          session_id: session.id,
          key: "auth_task",
          value: "user is migrating auth from cookie to JWT",
          kind: :goal,
          importance: 4
        })

      {:ok, _} =
        Agent.put_global_memory(%{
          scope: :general,
          key: "language_pref",
          value: "user prefers Elixir over Python",
          kind: :preference,
          importance: 5
        })

      {:ok, _} =
        Agent.put_global_memory(%{
          scope: :general,
          key: "music",
          value: "loves jazz",
          kind: :fact,
          importance: 1
        })

      hits = Recall.recall("auth jwt migrate", session_id: session.id, limit: 5)
      assert [%{type: :session, row: %{key: "auth_task"}} | _] = hits
    end

    test "scope: :global filters out session memories", %{session: session} do
      {:ok, _} =
        Agent.put_session_memory(%{
          session_id: session.id,
          key: "x",
          value: "session only",
          kind: :fact
        })

      {:ok, _} =
        Agent.put_global_memory(%{scope: :general, key: "y", value: "session only", kind: :fact})

      hits = Recall.recall("session only", scope: :global, session_id: session.id, limit: 5)
      assert Enum.all?(hits, &(&1.type == :global))
    end

    test "bump: true increments hit_count and last_used_at on hits", %{session: session} do
      {:ok, row} =
        Agent.put_session_memory(%{
          session_id: session.id,
          key: "bumpme",
          value: "rocket science",
          kind: :fact
        })

      assert row.hit_count == 0
      _ = Recall.recall("rocket science", session_id: session.id, bump: true)

      {:ok, [updated]} = Agent.list_session_memory_for(session.id)
      assert updated.hit_count == 1
      assert updated.last_used_at != nil
    end

    test "format_for_prompt produces a sectioned addendum or empty string", %{session: session} do
      assert Recall.format_for_prompt([]) == ""

      {:ok, _} =
        Agent.put_session_memory(%{
          session_id: session.id,
          key: "favorite_color",
          value: "violet",
          kind: :preference
        })

      hits = Recall.recall("favorite color violet", session_id: session.id)
      formatted = Recall.format_for_prompt(hits)

      assert formatted =~ "Relevant memory"
      assert formatted =~ "[session] favorite_color: violet"
    end

    test "ranking favours higher importance when scores tie", %{session: session} do
      {:ok, _} =
        Agent.put_session_memory(%{
          session_id: session.id,
          key: "high",
          value: "spaceship",
          kind: :fact,
          importance: 5
        })

      {:ok, _} =
        Agent.put_session_memory(%{
          session_id: session.id,
          key: "low",
          value: "spaceship",
          kind: :fact,
          importance: 1
        })

      [first | _] = Recall.recall("spaceship", session_id: session.id, limit: 2)
      assert first.row.key == "high"
    end
  end
end
