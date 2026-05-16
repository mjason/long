defmodule LongWeb.AgentLive.ChatTest do
  use LongWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Long.Agent
  alias Long.Agent.SessionRunner

  describe "mount" do
    test "creates a new session and renders empty chat", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/chat/new")

      assert html =~ "New session"
      assert html =~ "echo (demo)"
      assert has_element?(view, "form[phx-submit=submit]")
    end

    test "mounts an existing session by id", %{conn: conn} do
      {:ok, sess} = Agent.start_session(%{title: "mine"})

      {:ok, _view, html} = live(conn, ~p"/chat/#{sess.id}")
      assert html =~ "mine"
    end
  end

  describe "SessionRunner with Echo backend" do
    setup do
      {:ok, sess} = Agent.start_session(%{title: "echo-test"})
      :ok = SessionRunner.subscribe(sess.id)
      {:ok, sess: sess}
    end

    test "broadcasts loop lifecycle + persists user/assistant messages", %{sess: sess} do
      :ok = SessionRunner.send_user_message(sess.id, "hi there")

      # Lifecycle: user message persisted → loop_started → text deltas → loop_ended
      assert_receive {:message_persisted, %{message: %{role: :user, content: "hi there"}}}, 1_000
      assert_receive :loop_started, 1_000

      # Loop translates SSE text deltas into :llm_chunk events for consumers
      assert_receive {:llm_chunk, _}, 1_000

      # The Loop emits {:llm_done, _resp} once it reaches Response struct
      assert_receive {:llm_done, _}, 1_000

      # Loop ends with :no_tool_call (Echo never calls tools)
      assert_receive {:done, %{reason: :no_tool_call}}, 1_000
      assert_receive :loop_ended, 1_000

      # And we should have an assistant message persisted with the echo text
      {:ok, all} = Agent.list_messages()
      assistant = Enum.find(all, &(&1.session_id == sess.id and &1.role == :assistant))
      assert assistant != nil
      assert assistant.content =~ "(echo) hi there"
    end
  end

  describe "LiveView end-to-end with Echo backend" do
    test "submitting a message streams the echo back into the DOM", %{conn: conn} do
      {:ok, sess} = Agent.start_session(%{title: "e2e"})
      {:ok, view, _html} = live(conn, ~p"/chat/#{sess.id}")

      # Subscribe the test process so we can synchronize on :loop_ended
      :ok = SessionRunner.subscribe(sess.id)

      view |> form("form[phx-submit=submit]", input: "ping") |> render_submit()

      assert_receive :loop_ended, 2_000

      html = render(view)
      assert html =~ "ping"
      assert html =~ "(echo) ping"
    end
  end
end
