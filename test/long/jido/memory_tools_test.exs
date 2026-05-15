defmodule Long.Jido.MemoryToolsTest do
  use Long.DataCase, async: false

  alias Long.Agent
  alias Long.Jido.Tools.{MemoryRecall, MemoryRemember}

  setup do
    {:ok, session} = Agent.start_session(%{title: "memory-tools"})
    ctx = %{session_id: session.id}
    {:ok, session: session, ctx: ctx}
  end

  describe "MemoryRemember" do
    test "writes session memory by default", %{session: session, ctx: ctx} do
      assert {:ok, %{status: "success", scope: "session", key: "k1"}} =
               Jido.Exec.run(
                 MemoryRemember,
                 %{key: "k1", value: "v1", kind: "preference", importance: 4},
                 ctx
               )

      {:ok, [row]} = Agent.list_session_memory_for(session.id)
      assert row.value == "v1"
      assert row.kind == :preference
      assert row.importance == 4
    end

    test "scope=global writes to GlobalMemory", %{ctx: ctx} do
      assert {:ok, %{status: "success", scope: "global"}} =
               Jido.Exec.run(
                 MemoryRemember,
                 %{scope: "global", key: "tz", value: "UTC+8", kind: "fact"},
                 ctx
               )

      {:ok, rows} = Agent.list_global_memory()
      assert Enum.any?(rows, &(&1.key == "tz" and &1.value == "UTC+8"))
    end

    test "rejects empty key", %{ctx: ctx} do
      assert {:ok, %{status: "error", msg: msg}} =
               Jido.Exec.run(MemoryRemember, %{key: "", value: "v"}, ctx)

      assert msg =~ "key"
    end

    test "rejects invalid scope", %{ctx: ctx} do
      assert {:ok, %{status: "error", msg: msg}} =
               Jido.Exec.run(MemoryRemember, %{scope: "weird", key: "k", value: "v"}, ctx)

      assert msg =~ "invalid scope"
    end

    test "rejects invalid kind", %{ctx: ctx} do
      assert {:ok, %{status: "error", msg: msg}} =
               Jido.Exec.run(MemoryRemember, %{key: "k", value: "v", kind: "??"}, ctx)

      assert msg =~ "invalid kind"
    end

    test "session scope without session_id fails", _ do
      assert {:ok, %{status: "error", msg: msg}} =
               Jido.Exec.run(MemoryRemember, %{key: "k", value: "v"}, %{})

      assert msg =~ "session"
    end

    test "same key upserts in same session", %{session: session, ctx: ctx} do
      Jido.Exec.run(MemoryRemember, %{key: "k", value: "first"}, ctx)
      Jido.Exec.run(MemoryRemember, %{key: "k", value: "second"}, ctx)

      {:ok, [row]} = Agent.list_session_memory_for(session.id)
      assert row.value == "second"
    end
  end

  describe "MemoryRecall" do
    setup %{session: session, ctx: ctx} do
      Jido.Exec.run(
        MemoryRemember,
        %{key: "auth", value: "moving from cookie to JWT", kind: "goal", importance: 4},
        ctx
      )

      Jido.Exec.run(
        MemoryRemember,
        %{scope: "global", key: "lang", value: "Elixir preferred", kind: "preference", importance: 5},
        ctx
      )

      {:ok, session: session}
    end

    test "finds matching session + global memories", %{ctx: ctx} do
      assert {:ok, %{status: "success", count: c, matches: matches}} =
               Jido.Exec.run(MemoryRecall, %{query: "Elixir"}, ctx)

      assert c >= 1
      assert Enum.any?(matches, &(&1.key == "lang"))
    end

    test "scope filter limits to global", %{ctx: ctx} do
      assert {:ok, %{matches: matches}} =
               Jido.Exec.run(MemoryRecall, %{query: "auth", scope: "global"}, ctx)

      refute Enum.any?(matches, &(&1.scope == "session"))
    end

    test "rejects empty query", %{ctx: ctx} do
      assert {:ok, %{status: "error", msg: msg}} =
               Jido.Exec.run(MemoryRecall, %{query: ""}, ctx)

      assert msg =~ "query"
    end

    test "bumps hit_count after recall", %{session: session, ctx: ctx} do
      _ = Jido.Exec.run(MemoryRecall, %{query: "JWT"}, ctx)

      {:ok, [row]} = Agent.list_session_memory_for(session.id)
      assert row.hit_count >= 1
    end
  end
end
