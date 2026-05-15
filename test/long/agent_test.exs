defmodule Long.AgentTest do
  @moduledoc """
  Phase 0 smoke test: every Agent resource is reachable through its domain
  code interface and persists round-trip via AshSqlite.
  """
  use Long.DataCase, async: false

  alias Long.Agent

  describe "sessions" do
    test "start/get/list/archive roundtrip" do
      assert {:ok, session} =
               Agent.start_session(%{title: "first run", llm_alias: "claude_main"})

      assert session.status == :active
      assert session.token_usage == 0

      assert {:ok, fetched} = Agent.get_session(session.id)
      assert fetched.title == "first run"

      assert {:ok, [_]} = Agent.list_sessions()

      assert {:ok, archived} = Agent.archive_session(session.id)
      assert archived.status == :archived
      assert not is_nil(archived.ended_at)
    end
  end

  describe "messages" do
    test "append and order by turn" do
      {:ok, s} = Agent.start_session(%{title: "with-msgs"})

      {:ok, _} =
        Agent.append_message(%{
          session_id: s.id,
          role: :user,
          content: "hello",
          turn: 1
        })

      {:ok, _} =
        Agent.append_message(%{
          session_id: s.id,
          role: :assistant,
          content: "hi back",
          turn: 1,
          blocks: %{"type" => "text", "text" => "hi back"}
        })

      assert {:ok, msgs} = Agent.list_messages()
      assert length(msgs) == 2
      assert Enum.map(msgs, & &1.role) == [:user, :assistant]
    end
  end

  describe "working checkpoint" do
    test "upsert is idempotent per session" do
      {:ok, s} = Agent.start_session(%{title: "wc"})

      {:ok, cp1} = Agent.upsert_checkpoint(%{session_id: s.id, key_info: "v1"})
      {:ok, cp2} = Agent.upsert_checkpoint(%{session_id: s.id, key_info: "v2"})

      assert cp1.id == cp2.id
      assert cp2.key_info == "v2"

      assert {:ok, fetched} = Agent.get_checkpoint(s.id)
      assert fetched.key_info == "v2"
    end
  end

  describe "global memory" do
    test "upsert respects (scope, key) identity" do
      {:ok, a} = Agent.put_global_memory(%{scope: :insight, key: "tone", value: "concise"})
      {:ok, b} = Agent.put_global_memory(%{scope: :insight, key: "tone", value: "concise+"})

      assert a.id == b.id
      assert b.value == "concise+"

      {:ok, c} = Agent.put_global_memory(%{scope: :general, key: "tone", value: "free"})
      assert c.id != a.id

      assert {:ok, all} = Agent.list_global_memory()
      assert length(all) == 2
    end
  end

  describe "session archive" do
    test "store payload independent of source session lifecycle" do
      {:ok, s} = Agent.start_session(%{title: "to-archive"})

      {:ok, arch} =
        Agent.archive_payload(%{
          original_session_id: s.id,
          title: s.title,
          summary: "summary",
          insights: "lesson",
          payload: %{"messages" => []}
        })

      assert arch.original_session_id == s.id

      :ok = Ash.destroy!(s)
      assert {:ok, [_]} = Agent.list_archives()
    end
  end

  describe "llm config" do
    test "register and update by alias" do
      {:ok, c} =
        Agent.register_llm(%{
          alias: "claude_main",
          kind: :claude,
          model: "claude-opus-4-7",
          api_base: "https://api.anthropic.com",
          api_key_env_var: "ANTHROPIC_API_KEY",
          params: %{"max_tokens" => 8192}
        })

      assert c.enabled
      assert c.params["max_tokens"] == 8192

      {:ok, c2} =
        Agent.register_llm(%{
          alias: "claude_main",
          kind: :claude,
          model: "claude-opus-4-7",
          api_base: "https://api.anthropic.com",
          api_key_env_var: "ANTHROPIC_API_KEY",
          params: %{"max_tokens" => 16_000},
          enabled: false
        })

      assert c.id == c2.id
      assert c2.params["max_tokens"] == 16_000
      refute c2.enabled
    end
  end
end
