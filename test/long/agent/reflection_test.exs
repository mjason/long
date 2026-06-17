defmodule Long.Agent.ReflectionTest do
  @moduledoc """
  Silent reflection — the autonomous "tidy your own memory" loop. These
  tests lock the invariants the design depends on, especially the ones
  that matter under multi-user concurrency: structural silence (a
  reflection turn physically cannot reach a channel or write shared/global
  state), internal-row visibility (hidden from web + public GraphQL, but
  visible to the agent's own History replay), the activity gate, and that
  reflection never deadlocks L4 archival.
  """
  use Long.DataCase, async: false
  use Oban.Testing, repo: Long.Repo

  require Ash.Query

  alias Long.Agent
  alias Long.Agent.{Server, ScheduledTask, SessionRunner}
  alias Long.Agent.Workers.{L4Archive, RunScheduledTask}
  alias Long.Jido.Loop
  alias Long.Jido.Tools.GraphQLReflection
  alias Long.Test.LLMConsumerMock

  # ── Structural silence: the reduced tool set ────────────────────────

  describe "SessionRunner.reflection_tools/0" do
    test "is exactly the restricted GraphQL tool — no channel or side-effect tools" do
      tools = Long.Jido.SessionRunner.reflection_tools()

      assert tools == [GraphQLReflection]

      # The whole point: even if the model tries, these aren't in the turn.
      for forbidden <- [
            Long.Jido.Tools.NotifyMember,
            Long.Jido.Tools.SendMedia,
            Long.Jido.Tools.AskUser,
            Long.Jido.Tools.CodeRun,
            Long.Jido.Tools.HttpFetch,
            Long.Jido.Tools.WebExecuteJs,
            Long.Jido.Tools.FileWrite,
            Long.Jido.Tools.SkillCreate,
            # full GraphQL (teaches/permits putGlobalMemory) is replaced
            Long.Jido.Tools.GraphQL
          ] do
        refute forbidden in tools
      end
    end
  end

  # ── The write boundary (security-critical) ──────────────────────────

  describe "GraphQLReflection write boundary" do
    test "refuses putGlobalMemory and writes nothing" do
      q =
        ~s|mutation { putGlobalMemory(input: {scope: GENERAL, key: "leak", value: "x", kind: FACT, importance: 3}) { result { id } } }|

      assert {:ok, %{status: "error", errors: [%{message: msg}]}} =
               GraphQLReflection.run(%{query: q, variables: %{}}, %{})

      assert msg =~ "not allowed during silent reflection"
      assert {:ok, []} = Agent.list_global_memory()
    end

    test "refuses createScheduledTask — a reflection turn can't mint new tasks (no self-amplification)" do
      q =
        ~s|mutation { createScheduledTask(input: {name: "x", sessionId: "00000000-0000-0000-0000-000000000000", prompt: "p", repeat: DAILY, scheduleTime: "08:00"}) { result { id } } }|

      assert {:ok, %{status: "error"}} = GraphQLReflection.run(%{query: q, variables: %{}}, %{})
    end

    test "an alias on the field name does not bypass the check" do
      q =
        ~s|mutation { sneaky: putGlobalMemory(input: {scope: GENERAL, key: "k", value: "v", kind: FACT, importance: 3}) { result { id } } }|

      assert {:ok, %{status: "error"}} = GraphQLReflection.run(%{query: q, variables: %{}}, %{})
      assert {:ok, []} = Agent.list_global_memory()
    end

    test "allows putSessionMemory — this session's own memory" do
      {:ok, sess} = Agent.start_session(%{title: "ref-write"})

      q =
        ~s|mutation { putSessionMemory(input: {sessionId: "#{sess.id}", key: "k", value: "v", kind: FACT, importance: 3}) { result { id } errors { message } } }|

      assert {:ok, %{status: status}} =
               GraphQLReflection.run(%{query: q, variables: %{}}, %{session_id: sess.id})

      assert status in ["success", "partial"]

      {:ok, rows} = Agent.list_session_memory_for(sess.id)
      assert Enum.any?(rows, &(&1.key == "k"))
    end

    test "refuses writing ANOTHER session's checkpoint (cross-session pin)" do
      {:ok, mine} = Agent.start_session(%{title: "mine"})
      {:ok, other} = Agent.start_session(%{title: "other"})

      q =
        ~s|mutation { putWorkingCheckpoint(input: {sessionId: "#{other.id}", keyInfo: "stolen"}) { result { id } } }|

      assert {:ok, %{status: "error", errors: [%{message: msg}]}} =
               GraphQLReflection.run(%{query: q, variables: %{}}, %{session_id: mine.id})

      assert msg =~ "OWN session"
      assert {:error, _} = Agent.get_checkpoint(other.id)
    end

    test "refuses a cross-session write smuggled through a GraphQL variable" do
      {:ok, mine} = Agent.start_session(%{title: "mine"})
      {:ok, other} = Agent.start_session(%{title: "other"})

      q =
        ~s|mutation($s: ID!) { putSessionMemory(input: {sessionId: $s, key: "k", value: "v", kind: FACT, importance: 3}) { result { id } } }|

      assert {:ok, %{status: "error"}} =
               GraphQLReflection.run(
                 %{query: q, variables: %{"s" => other.id}},
                 %{session_id: mine.id}
               )

      assert {:ok, []} = Agent.list_session_memory_for(other.id)
    end

    test "an introspection meta-field beside an allowed mutation is fine" do
      {:ok, sess} = Agent.start_session(%{title: "meta"})

      q =
        ~s|mutation { __typename putSessionMemory(input: {sessionId: "#{sess.id}", key: "k", value: "v", kind: FACT, importance: 3}) { result { id } } }|

      assert {:ok, %{status: status}} =
               GraphQLReflection.run(%{query: q, variables: %{}}, %{session_id: sess.id})

      assert status in ["success", "partial"]
    end

    test "allows reads unconditionally" do
      assert {:ok, %{status: "success"}} =
               GraphQLReflection.run(
                 %{query: "{ __schema { queryType { name } } }", variables: %{}},
                 %{session_id: "any"}
               )
    end
  end

  # ── M1: the whole-table GraphQL surface hides internal rows ──────────

  describe "GraphQL message queries vs internal rows" do
    test "the whole-table `messages` query never returns internal reflection rows" do
      {:ok, sess} = Agent.start_session(%{title: "leak-check"})
      {:ok, _} = Agent.append_message(%{session_id: sess.id, role: :user, content: "VISIBLE_ROW", turn: 1})

      {:ok, _} =
        Agent.append_message(%{
          session_id: sess.id,
          role: :assistant,
          content: "SECRET_INTERNAL",
          turn: 1,
          internal: true
        })

      {:ok, res} =
        Absinthe.run("query { messages(first: 100) { results { content } } }", LongWeb.GraphqlSchema)

      contents = get_in(res, [:data, "messages", "results"]) |> Enum.map(& &1["content"])
      assert "VISIBLE_ROW" in contents
      refute "SECRET_INTERNAL" in contents
    end

    test "the `internal` flag is not even selectable from GraphQL" do
      {:ok, res} = Absinthe.run("query { messages { results { internal } } }", LongWeb.GraphqlSchema)
      assert res[:errors] not in [nil, []]
    end
  end

  # ── A reflection turn driven through the real Server ─────────────────

  describe "reflection turn via Server" do
    setup :with_llm_session

    test "marks rows internal, emits no PubSub, leaves the activity clock untouched", %{
      session: session
    } do
      SessionRunner.subscribe(session.id)
      LLMConsumerMock.push_response(session.id, %{type: :final_answer, text: "tidied"})

      :ok =
        Server.send_user_message(session.id, Loop.reflection_trigger_prompt(),
          reflection?: true,
          internal: true,
          llm_consumer: LLMConsumerMock
        )

      # Silent end to end: no message reload, no spinner lifecycle.
      refute_receive {:message_persisted, _}, 700
      refute_receive :loop_ended, 100

      rows = wait_for_internal_rows(session.id)
      assert Enum.all?(rows, & &1.internal)
      assert Enum.any?(rows, &(&1.role == :assistant))

      # The synthetic trigger is internal, so it doesn't count as human
      # activity — the gate won't re-fire forever.
      assert Agent.last_human_message_at(session.id) == nil
    end

    test "internal rows are hidden from the public list but visible to History replay", %{
      session: session
    } do
      LLMConsumerMock.push_response(session.id, %{type: :final_answer, text: "tidied"})

      :ok =
        Server.send_user_message(session.id, Loop.reflection_trigger_prompt(),
          reflection?: true,
          internal: true,
          llm_consumer: LLMConsumerMock
        )

      _ = wait_for_internal_rows(session.id)

      # In-process (:by_session) — what History/TitleGen see — keeps them.
      {:ok, in_process} = Agent.list_messages_for_session(session.id)
      assert Enum.any?(in_process, & &1.internal)

      # Public (:by_session_public) — the GraphQL surface — hides them.
      {:ok, public} =
        Long.Agent.Message
        |> Ash.Query.for_read(:by_session_public, %{session_id: session.id})
        |> Ash.read()

      refute Enum.any?(public, & &1.internal)
    end

    test "a normal (non-reflection) turn still broadcasts and stays visible", %{session: session} do
      SessionRunner.subscribe(session.id)
      LLMConsumerMock.push_response(session.id, %{type: :final_answer, text: "hi"})

      :ok = Server.send_user_message(session.id, "hello", llm_consumer: LLMConsumerMock)

      assert_receive {:message_persisted, _}, 2_000
      assert_receive :loop_ended, 2_000

      {:ok, all} = Agent.list_messages()
      user = Enum.find(all, &(&1.session_id == session.id and &1.role == :user))
      refute user.internal
    end

    test "a normal human turn auto-seeds the session's daily reflection task (closed loop)",
         %{session: session} do
      # A member must exist for the web session to resolve to (the owner).
      {:ok, group} = Agent.create_group(%{name: "g"})

      {:ok, _member} =
        Agent.create_member(%{group_id: group.id, display_name: "me", relation: :self, role: :owner})

      SessionRunner.subscribe(session.id)
      LLMConsumerMock.push_response(session.id, %{type: :final_answer, text: "hi"})
      :ok = Server.send_user_message(session.id, "hello", llm_consumer: LLMConsumerMock)
      assert_receive :loop_ended, 2_000

      # Seeding is fire-and-forget under the task supervisor.
      assert wait_for_reflection_task(session.id)
      {:ok, task} = Agent.get_scheduled_task_by_name(Agent.reflection_task_name(session.id))
      assert task.silent
      assert task.repeat == :daily
    end
  end

  # ── The trigger chain + activity gate ───────────────────────────────

  describe "RunScheduledTask silent dispatch" do
    setup :with_llm_session

    test "fires a reflection when there's fresh human activity", %{session: session} do
      {:ok, _} =
        Agent.append_message(%{session_id: session.id, role: :user, content: "hi", turn: 1})

      task = silent_task(session.id)
      LLMConsumerMock.push_response(session.id, %{type: :final_answer, text: "tidied"})

      assert :ok = perform_job(RunScheduledTask, %{"task_id" => task.id})

      assert wait_for_internal_rows(session.id) != []
    end

    test "gates (no LLM turn) when the last reflection is newer than the last human message",
         %{session: session} do
      {:ok, _} =
        Agent.append_message(%{session_id: session.id, role: :user, content: "hi", turn: 1})

      # An internal reflection row that lands AFTER the human message — the
      # gate's "last reflected" anchor, newer than the last human activity.
      {:ok, _} =
        Agent.append_message(%{
          session_id: session.id,
          role: :assistant,
          content: "already tidied",
          turn: 2,
          internal: true
        })

      task = silent_task(session.id)

      assert :ok = perform_job(RunScheduledTask, %{"task_id" => task.id})
      Process.sleep(100)
      # No NEW reflection ran — only the pre-existing internal row remains.
      assert count_internal(session.id) == 1
    end

    test "gates a session with no human messages at all (e.g. freshly /cleared)", %{
      session: session
    } do
      task = silent_task(session.id)

      assert :ok = perform_job(RunScheduledTask, %{"task_id" => task.id})
      Process.sleep(100)
      assert count_internal(session.id) == 0
    end

    test "the instance kill switch disables silent dispatch", %{session: session} do
      {:ok, _} =
        Agent.append_message(%{session_id: session.id, role: :user, content: "hi", turn: 1})

      task = silent_task(session.id)

      Application.put_env(:long, Long.Agent.Reflection, enabled: false)

      on_exit(fn ->
        Application.put_env(:long, Long.Agent.Reflection, enabled: true, hour: 18)
      end)

      assert :ok = perform_job(RunScheduledTask, %{"task_id" => task.id})
      Process.sleep(100)
      assert count_internal(session.id) == 0
    end
  end

  # ── L4 archival is not defeated by reflection rows ──────────────────

  describe "L4Archive vs reflection rows" do
    setup do
      Application.put_env(:long, Long.Agent,
        memory_root: Path.expand("priv/agent/memory", File.cwd!()),
        temp_root: Path.expand("priv/agent/temp", File.cwd!()),
        archive: [idle_hours: 0]
      )

      on_exit(fn -> Application.delete_env(:long, Long.Agent) end)
      :ok
    end

    test "a session whose only recent rows are internal still archives, and its task is disabled" do
      {:ok, sess} = Agent.start_session(%{title: "arch"})
      {:ok, _} = Agent.append_message(%{session_id: sess.id, role: :user, content: "hi", turn: 1})

      {:ok, _} =
        Agent.append_message(%{
          session_id: sess.id,
          role: :assistant,
          content: "tidied",
          turn: 2,
          internal: true
        })

      task = silent_task(sess.id)

      assert :ok = perform_job(L4Archive, %{})

      {:ok, refetched} = Agent.get_session(sess.id)
      assert refetched.status == :archived

      {:ok, t} = Agent.get_scheduled_task(task.id)
      refute t.enabled
    end
  end

  # ── Seeding lifecycle ───────────────────────────────────────────────

  describe "Agent.ensure_reflection_task/2" do
    test "skips when the session has no member to act for" do
      {:ok, sess} = Agent.start_session(%{title: "stranger"})
      assert {:ok, :skipped} = Agent.ensure_reflection_task(sess.id)
    end

    test "creates a silent daily task with an explicit next_run_at, idempotently" do
      {:ok, group} = Agent.create_group(%{name: "g"})

      {:ok, _member} =
        Agent.create_member(%{
          group_id: group.id,
          display_name: "me",
          relation: :self,
          role: :owner
        })

      {:ok, sess} = Agent.start_session(%{title: "owned"})

      assert {:ok, %ScheduledTask{} = task} = Agent.ensure_reflection_task(sess.id)
      assert task.silent
      assert task.repeat == :daily
      assert task.max_delay_hours == 1
      # Explicit next_run_at — no cold-start "fire immediately" storm.
      assert task.next_run_at != nil
      assert task.name == Agent.reflection_task_name(sess.id)

      assert {:ok, %ScheduledTask{id: same}} = Agent.ensure_reflection_task(sess.id)
      assert same == task.id

      {:ok, all} = Agent.list_scheduled_tasks()
      assert Enum.count(all, &(&1.name == Agent.reflection_task_name(sess.id))) == 1
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp with_llm_session(_ctx) do
    LLMConsumerMock.setup_table()
    LLMConsumerMock.reset()
    Application.put_env(:long, :llm_consumer, LLMConsumerMock)

    {:ok, _llm} =
      Agent.register_llm(%{
        alias: "test_llm",
        kind: :openai,
        provider: "openai",
        model: "test-model",
        enabled: true,
        default: true
      })

    {:ok, session} = Agent.start_session(%{title: "reflection", llm_alias: "test_llm"})

    on_exit(fn ->
      Server.terminate_session(session.id)
      LLMConsumerMock.reset()
      Application.delete_env(:long, :llm_consumer)
    end)

    {:ok, session: session}
  end

  defp silent_task(session_id) do
    {:ok, task} =
      Agent.create_scheduled_task(%{
        name: Agent.reflection_task_name(session_id),
        session_id: session_id,
        prompt: Loop.reflection_trigger_prompt(),
        repeat: :daily,
        silent: true
      })

    task
  end

  defp count_internal(session_id) do
    {:ok, all} = Agent.list_messages()
    Enum.count(all, &(&1.session_id == session_id and &1.internal))
  end

  defp wait_for_reflection_task(session_id, tries \\ 60) do
    case Agent.get_scheduled_task_by_name(Agent.reflection_task_name(session_id)) do
      {:ok, _task} -> true
      _ when tries == 0 -> false
      _ -> Process.sleep(25) && wait_for_reflection_task(session_id, tries - 1)
    end
  end

  defp wait_for_internal_rows(session_id, tries \\ 60) do
    {:ok, all} = Agent.list_messages()
    rows = Enum.filter(all, &(&1.session_id == session_id and &1.internal))

    cond do
      rows != [] -> rows
      tries == 0 -> flunk("no internal reflection rows appeared for #{session_id}")
      true -> Process.sleep(25) && wait_for_internal_rows(session_id, tries - 1)
    end
  end
end
