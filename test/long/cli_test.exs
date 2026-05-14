defmodule Long.CLITest do
  use Long.DataCase, async: false

  # Captures every call to `puts/write/gets` so we can assert on what the
  # CLI would have shown the user. `gets/1` returns each line from
  # `:lines` in order, then `:eof`. `Elixir.Agent` is fully-qualified
  # because the outer module aliases `Long.Agent` to `Agent`.
  defmodule StubIO do
    def new(lines \\ []) do
      {:ok, pid} =
        Elixir.Agent.start_link(fn -> %{out: [], lines: lines} end, name: :stub_io_state)

      pid
    end

    def reset(lines \\ []) do
      Elixir.Agent.update(:stub_io_state, fn _ -> %{out: [], lines: lines} end)
    end

    def output do
      Elixir.Agent.get(:stub_io_state, fn s -> Enum.reverse(s.out) |> Enum.join() end)
    end

    def puts(text) do
      Elixir.Agent.update(:stub_io_state, fn s -> %{s | out: [text <> "\n" | s.out]} end)
    end

    def write(text) do
      Elixir.Agent.update(:stub_io_state, fn s -> %{s | out: [text | s.out]} end)
    end

    def gets(_prompt) do
      Elixir.Agent.get_and_update(:stub_io_state, fn s ->
        case s.lines do
          [] -> {:eof, s}
          [h | t] -> {h <> "\n", %{s | lines: t}}
        end
      end)
    end
  end

  setup do
    case Process.whereis(:stub_io_state) do
      nil -> :ok
      pid -> Process.alive?(pid) && Elixir.Agent.stop(pid)
    end

    StubIO.new()
    :ok
  end

  describe "Long.CLI.run_once/2" do
    test "prints streamed text and returns the accumulated response (Echo backend)" do
      assert {:ok, text} = Long.CLI.run_once("hi cli", io: StubIO, title: "cli-test")
      assert text =~ "(echo) hi cli"
      assert StubIO.output() =~ "(echo) hi cli"
    end

    test "resumes an existing session by id" do
      {:ok, sess} = Long.Agent.start_session(%{title: "preexisting"})

      assert {:ok, _} = Long.CLI.run_once("greetings", io: StubIO, session_id: sess.id)

      {:ok, all_msgs} = Long.Agent.list_messages()
      sess_msgs = Enum.filter(all_msgs, &(&1.session_id == sess.id))
      assert Enum.any?(sess_msgs, &(&1.content == "greetings"))
    end
  end

  describe "Long.CLI.chat_loop/1" do
    test "loops over stdin lines, replies, and exits cleanly on /exit" do
      StubIO.reset(["one", "/exit"])

      assert :ok = Long.CLI.chat_loop(io: StubIO, title: "chat-test")

      out = StubIO.output()
      assert out =~ "Long agent CLI"
      assert out =~ "(echo) one"
    end

    test "/reset starts a new session" do
      StubIO.reset(["/reset", "/exit"])

      assert :ok = Long.CLI.chat_loop(io: StubIO, title: "reset-test")
      assert StubIO.output() =~ "new session:"
    end
  end

  describe "Long.CLI.list_sessions/1" do
    test "prints (no sessions) when empty" do
      Long.CLI.list_sessions(io: StubIO)
      assert StubIO.output() =~ "(no sessions)"
    end

    test "prints each session in descending order" do
      {:ok, _} = Long.Agent.start_session(%{title: "alpha"})
      {:ok, _} = Long.Agent.start_session(%{title: "bravo"})

      Long.CLI.list_sessions(io: StubIO)
      out = StubIO.output()
      assert out =~ "alpha"
      assert out =~ "bravo"
    end
  end
end
