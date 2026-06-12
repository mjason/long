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

  describe "attachments" do
    test "uploading a file then submitting stores it under the session web_inbox", %{conn: conn} do
      {:ok, sess} = Agent.start_session(%{title: "upload"})
      on_exit(fn -> File.rm_rf(Agent.web_inbox_dir(sess.id)) end)

      {:ok, view, _html} = live(conn, ~p"/chat/#{sess.id}")
      :ok = SessionRunner.subscribe(sess.id)

      up =
        file_input(view, "#composer", :attachments, [
          %{name: "notes.txt", content: "hello file", type: "text/plain"}
        ])

      render_upload(up, "notes.txt")
      view |> form("#composer", input: "read this") |> render_submit()

      assert_receive :loop_ended, 2_000

      files = File.ls!(Agent.web_inbox_dir(sess.id))
      assert Enum.any?(files, &(&1 =~ "notes"))
    end
  end

  describe "ask_user prompt" do
    test "clears when the turn resumes (e.g. answered from another channel)", %{conn: conn} do
      {:ok, sess} = Agent.start_session(%{title: "ask"})
      {:ok, view, _html} = live(conn, ~p"/chat/#{sess.id}")

      # Agent asks → the card shows the question.
      send(view.pid, {:ask_user, %{"question" => "Which one — A or B?", "candidates" => []}})
      assert render(view) =~ "Which one — A or B?"

      # Answered elsewhere (e.g. WeChat) → server starts the next turn → clears.
      send(view.pid, :loop_started)
      refute render(view) =~ "Which one — A or B?"
    end
  end
end
