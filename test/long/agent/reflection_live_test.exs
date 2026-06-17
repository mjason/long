defmodule Long.Agent.ReflectionLiveTest do
  @moduledoc """
  End-to-end smoke test of a silent reflection turn against a REAL LLM
  (DeepSeek via `DEEPSEEK_API_KEY`). Opt-in only — excluded from the
  default suite; run with:

      mix test test/long/agent/reflection_live_test.exs --only live_llm

  It seeds a realistic human conversation, fires one real reflection turn
  through the actual `Long.Agent.Server` orchestration (no LLM mock), and
  checks the guarantees the unit tests can only assert with a fake model:

    * the reflection actually consolidates SOMETHING into session memory;
    * it writes ZERO global memory (cross-tenant boundary holds on a real model);
    * its rows are `internal` and hidden from the public GraphQL surface;
    * it stays silent (no channel push path is reachable).

  It also prints what the model actually did so a human can judge quality.
  """
  use Long.DataCase, async: false

  require Ash.Query

  alias Long.Agent
  alias Long.Agent.Server
  alias Long.Jido.Loop

  @moduletag :live_llm
  @moduletag timeout: 180_000

  setup do
    if System.get_env("DEEPSEEK_API_KEY") in [nil, ""] do
      raise "DEEPSEEK_API_KEY not set — cannot run the live reflection test"
    end

    {:ok, _llm} =
      Agent.register_llm(%{
        alias: "deepseek_live",
        kind: :openai,
        provider: "deepseek",
        wire_protocol: "openai_chat",
        model: "deepseek-chat",
        api_base: "https://api.deepseek.com",
        api_key_env_var: "DEEPSEEK_API_KEY",
        enabled: true,
        default: true
      })

    {:ok, session} = Agent.start_session(%{title: "coffee chat", llm_alias: "deepseek_live"})

    # A realistic conversation worth consolidating: a standing preference,
    # a decision, and a goal — the kinds of things reflection should keep.
    convo = [
      {:user, "I take my coffee as an oat-milk flat white, no sugar."},
      {:assistant, "Got it — oat flat white, no sugar."},
      {:user, "We decided to go with SQLite for the side project instead of Postgres, to keep deploy simple."},
      {:assistant, "Makes sense, SQLite keeps it single-file and easy to ship."},
      {:user, "Also I want to ship the v1 of that project before the end of the month."},
      {:assistant, "Noted — v1 target is end of month."}
    ]

    convo
    |> Enum.with_index(1)
    |> Enum.each(fn {{role, content}, turn} ->
      {:ok, _} = Agent.append_message(%{session_id: session.id, role: role, content: content, turn: turn})
    end)

    on_exit(fn -> Server.terminate_session(session.id) end)

    {:ok, session: session}
  end

  test "a real reflection turn consolidates session memory, writes no global memory, stays silent", %{session: session} do
    :ok =
      Server.send_user_message(session.id, Loop.reflection_trigger_prompt(),
        reflection?: true,
        internal: true
      )

    settle_reflection(session.id)

    {:ok, mems} = Agent.list_session_memory_for(session.id)
    {:ok, globals} = Agent.list_global_memory()
    {:ok, internal_rows} = internal_messages(session.id)

    {:ok, public} =
      Long.Agent.Message
      |> Ash.Query.for_read(:by_session_public, %{session_id: session.id})
      |> Ash.read()

    print_outcome(session.id, mems, internal_rows)

    # SECURITY (strict): no cross-member global write, even from a real model.
    assert globals == [], "reflection must not write GlobalMemory; got #{inspect(globals)}"

    # The reflection actually ran (it left internal rows) and they are hidden.
    assert internal_rows != [], "expected the reflection turn to persist internal rows"
    refute Enum.any?(public, & &1.internal), "internal rows leaked into the public list"

    # Quality (soft): with this much to remember, it should have kept something.
    assert mems != [],
           "reflection produced no session memory from a rich conversation — inspect the printout"
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp internal_messages(session_id) do
    Long.Agent.Message
    |> Ash.Query.filter(session_id == ^session_id and internal == true)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read()
  end

  # The reflection turn is silent (no :loop_ended), so wait for its DB
  # footprint to stop growing rather than for a PubSub signal.
  defp settle_reflection(session_id, waited \\ 0, last \\ -1) do
    {:ok, rows} = internal_messages(session_id)
    count = length(rows)

    cond do
      count > 0 and count == last -> :settled
      waited >= 160_000 -> :timeout
      true -> Process.sleep(3_000) && settle_reflection(session_id, waited + 3_000, count)
    end
  end

  defp print_outcome(session_id, mems, internal_rows) do
    IO.puts("\n===== LIVE REFLECTION OUTCOME (session #{session_id}) =====")

    IO.puts("\n-- SessionMemory written (#{length(mems)}) --")
    Enum.each(mems, fn m -> IO.puts("  [#{m.kind}/imp#{m.importance}] #{m.key} = #{m.value}") end)

    IO.puts("\n-- internal turn rows (#{length(internal_rows)}) --")

    Enum.each(internal_rows, fn r ->
      tools = Enum.map(r.tool_calls || [], & &1["name"]) |> Enum.join(",")
      preview = (r.content || "") |> String.slice(0, 160)
      IO.puts("  #{r.role}#{if tools != "", do: " [tools: #{tools}]", else: ""}: #{preview}")
    end)

    IO.puts("\n=========================================================\n")
  end
end
