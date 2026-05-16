defmodule Long.Agent.Bots.Wechat.Progress do
  @moduledoc """
  Narrates the agent's tool activity to a WeChat user while the
  reply is still being generated. Stays silent for short runs (the
  typing-indicator already covers those); after the run has been going
  for `@threshold_ms`, emits one short text per distinct tool kind so
  the user sees "正在搜索网页…" / "正在运行代码…" instead of staring at
  the typing bubble for 30 seconds with no idea what's happening.

  The WeChat protocol (Tencent/openclaw-weixin) does not expose any
  edit-message / update-message API, so each progress line is a
  separate sent message. De-duping per tool name keeps that to a
  handful at most over a long ReAct loop.
  """

  alias Long.Agent.Bots.Wechat.Client
  alias Long.SessionRunner

  @task_sup Long.Agent.TaskSup
  @threshold_ms 8_000
  # Defensive cap so a brutal-killed agent task (no `:loop_ended`
  # broadcast) doesn't leave us blocked in `receive` forever.
  @max_lifetime_ms 30 * 60_000

  @labels %{
    "web_search" => "🔍 正在搜索网页…",
    "web_scan" => "📖 正在阅读网页…",
    "web_execute_js" => "🧪 正在浏览器里执行脚本…",
    "http_fetch" => "🌐 正在请求接口…",
    "code_run" => "🐍 正在运行代码…",
    "file_read" => "📄 正在读取文件…",
    "file_write" => "📝 正在写入文件…",
    "file_patch" => "✏️ 正在修改文件…",
    "memory_recall" => "💭 正在回忆笔记…",
    "skill_search" => "🔎 正在查找技能…",
    "skill_read" => "📚 正在阅读技能手册…",
    "schedule_task" => "⏰ 正在安排定时任务…"
  }

  # Housekeeping tools — narrating them would be noisy without giving
  # the user any useful signal. `ask_user` in particular is *itself*
  # the user-facing event; the agent's pending question is what the
  # user sees, not a "正在问你…" preamble.
  @silent ~w(
    ask_user
    agent_status
    update_working_checkpoint
    start_long_term_update
    skill_reindex
    memory_remember
  )

  @spec start(map(), String.t(), String.t(), String.t() | nil) :: :ok
  def start(token, uid, session_id, ctx_token) do
    Task.Supervisor.start_child(@task_sup, fn ->
      SessionRunner.subscribe(session_id)

      loop(%{
        token: token,
        uid: uid,
        ctx: ctx_token,
        started_at: System.monotonic_time(:millisecond),
        seen: MapSet.new()
      })
    end)

    :ok
  end

  defp loop(state) do
    receive do
      :loop_ended -> :ok
      {:loop_error, _} -> :ok
      {:tool_start, %{name: name}} -> loop(maybe_emit(state, name))
      _ -> loop(state)
    after
      @max_lifetime_ms -> :ok
    end
  end

  defp maybe_emit(state, name) do
    elapsed = System.monotonic_time(:millisecond) - state.started_at
    key = to_string(name)

    cond do
      elapsed < @threshold_ms -> state
      key in @silent -> state
      MapSet.member?(state.seen, key) -> state
      true ->
        label = Map.get(@labels, key, "🛠 正在 #{key}…")
        _ = Client.send_text(state.token, state.uid, label, context_token: state.ctx)
        %{state | seen: MapSet.put(state.seen, key)}
    end
  end
end
