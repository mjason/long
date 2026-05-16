defmodule Long.CLI do
  @moduledoc """
  Shared helpers for the `mix long.*` CLI tasks. The CLI is a thin shell
  around `Long.Agent.SessionRunner` so the same code path that LiveView /
  Telegram / Feishu use is exercised from a terminal too.
  """

  alias Long.Agent
  alias Long.SessionRunner

  @io_module Application.compile_env(:long, [Long.CLI, :io_module], IO)

  @doc """
  Run `prompt` once against `session` (created if `:title` given), stream
  events to stdout, return the final accumulated text. Blocks until
  `:loop_ended`.
  """
  def run_once(prompt, opts \\ []) do
    session_id = resolve_session(opts)
    io = io_module(opts)

    :ok = SessionRunner.subscribe(session_id)

    try do
      :ok = SessionRunner.send_user_message(session_id, prompt)
      collect_stream(session_id, io, opts)
    after
      SessionRunner.unsubscribe(session_id)
    end
  end

  @doc "Interactive REPL: reads stdin lines, sends each as a user message."
  def chat_loop(opts \\ []) do
    session_id = resolve_session(opts)
    io = io_module(opts)

    io.puts("Long agent CLI · session #{session_id}")
    io.puts("Type a message, /reset for new session, /exit to quit.\n")

    do_chat(session_id, io, opts)
  end

  defp do_chat(session_id, io, opts) do
    case prompt_user(io) do
      :eof ->
        :ok

      "/exit" ->
        :ok

      "/reset" ->
        {:ok, sess} =
          Agent.start_session(%{
            title: "cli-#{System.unique_integer([:positive])}",
            llm_alias: Agent.default_llm_alias()
          })
        io.puts("[new session: #{sess.id}]")
        do_chat(sess.id, io, opts)

      "" ->
        do_chat(session_id, io, opts)

      text ->
        :ok = SessionRunner.subscribe(session_id)

        try do
          :ok = SessionRunner.send_user_message(session_id, text)
          collect_stream(session_id, io, opts)
        after
          SessionRunner.unsubscribe(session_id)
        end

        do_chat(session_id, io, opts)
    end
  end

  @doc "List recent sessions to stdout."
  def list_sessions(opts \\ []) do
    io = io_module(opts)

    case Agent.list_sessions() do
      {:ok, []} ->
        io.puts("(no sessions)")

      {:ok, rows} ->
        rows
        |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
        |> Enum.each(fn s ->
          io.puts(
            "#{s.id}  #{s.status}  #{s.title}  (#{Calendar.strftime(s.inserted_at, "%Y-%m-%d %H:%M")})"
          )
        end)
    end
  end

  # ── internals ───────────────────────────────────────────────────────────

  defp resolve_session(opts) do
    cond do
      id = Keyword.get(opts, :session_id) -> id
      title = Keyword.get(opts, :title) -> start_session!(title)
      true -> start_session!("cli-#{System.unique_integer([:positive])}")
    end
  end

  defp start_session!(title) do
    {:ok, sess} = Agent.start_session(%{title: title, llm_alias: Agent.default_llm_alias()})
    sess.id
  end

  defp prompt_user(io) do
    case io.gets("you> ") do
      :eof -> :eof
      {:error, _} -> :eof
      data -> String.trim(to_string(data))
    end
  end

  defp collect_stream(_session_id, io, opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 120_000)
    do_collect(io, %{text: "", current_tool: nil}, deadline)
  end

  defp do_collect(io, state, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      :loop_ended ->
        io.puts("")
        {:ok, state.text}

      {:llm_chunk, t} ->
        io.write(t)
        do_collect(io, %{state | text: state.text <> t}, deadline)

      {:llm_thinking, _t} ->
        do_collect(io, state, deadline)

      {:tool_start, %{name: name, args: args}} ->
        io.puts("\n🛠  #{name}(#{compact(args)})")
        do_collect(io, %{state | current_tool: name}, deadline)

      {:tool_output, t} ->
        io.write(t)
        do_collect(io, state, deadline)

      {:tool_done, %{name: name}} ->
        io.puts("✓ #{name} done")
        do_collect(io, %{state | current_tool: nil}, deadline)

      {:ask_user, payload} ->
        io.puts("\n❓ #{payload["question"]}")
        do_collect(io, state, deadline)

      {:loop_error, msg} ->
        io.puts("\n[error] #{msg}")
        do_collect(io, state, deadline)

      _other ->
        do_collect(io, state, deadline)
    after
      remaining ->
        io.puts("\n[timeout]")
        {:error, :timeout}
    end
  end

  defp compact(args) when is_map(args) do
    args
    |> Jason.encode!()
    |> String.slice(0, 80)
  end

  defp compact(_), do: ""

  defp io_module(opts), do: Keyword.get(opts, :io, @io_module)
end
