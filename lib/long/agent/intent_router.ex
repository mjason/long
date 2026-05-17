defmodule Long.Agent.IntentRouter do
  @moduledoc """
  Lightweight intent classifier that nudges the LLM toward the right
  tool when the user's message obviously maps to one — and clears any
  polluted history that contradicts it.

  Returns a `%{tool_choice, system_correction}` shape that
  `Long.Agent.Server.start_llm_turn/3` plumbs into the LLM call.

  Designed to be conservative: when in doubt, return `nil/nil` and let
  the model decide freely. False positives are worse than false
  negatives — forcing the wrong tool gives a wrong answer; not forcing
  just gives whatever the model would have done.
  """

  # Strong schedule signals — keep tight on purpose. Idle mentions of
  # "every day" without a time of day shouldn't trip this.
  @schedule_signals ~r/(?:定时|定期|cron\b|crontab|schedule_task|每隔\s*\d|每天\s*(?:早上|中午|下午|晚上|凌晨)?\s*\d+\s*[点时:：]|每周.*?\d+\s*[点时:：]|每月.*?\d+\s*[点时:：]|每\s*\d+\s*(?:小时|分钟|天))/iu

  # Assistant denials of scheduling capability — the model insisting it
  # can't schedule when it actually can. Match in recent assistant text
  # to decide whether to add a corrective system note.
  @schedule_denial_patterns ~r/(?:没有.*?(?:定时|内置.*?调度|schedule_task|任务中心|后台.*?调度)|无法.*?(?:定时|自动.*?触发)|不能.*?(?:自动|定时).*?(?:运行|跑|触发|唤醒)|cannot.*?(?:schedule|run.*?automatically)|don't.*?have.*?(?:scheduler|cron))/iu

  @doc """
  Classify `user_text` against `history` (recent ReqLLM messages) and
  `tools` (the modules in this turn's tool list). Returns:

      %{
        tool_choice: nil | binary,        # tool name to force
        system_correction: nil | binary   # extra system note to inject
      }
  """
  def classify(user_text, tools, history) when is_binary(user_text) and is_list(tools) do
    cond do
      schedule_intent?(user_text) and tool_available?(tools, "schedule_task") ->
        %{
          tool_choice: "schedule_task",
          system_correction: schedule_correction(history)
        }

      true ->
        %{tool_choice: nil, system_correction: nil}
    end
  end

  def classify(_, _, _), do: %{tool_choice: nil, system_correction: nil}

  defp schedule_intent?(text), do: text =~ @schedule_signals

  defp tool_available?(tools, name) do
    Enum.any?(tools, fn mod -> mod.name() == name end)
  end

  # Only add the correction if the model has *recently* denied this
  # capability. Otherwise the tool_choice alone is enough and we don't
  # want to nag.
  defp schedule_correction(history) do
    if recently_denied?(history, @schedule_denial_patterns) do
      """
      [SYSTEM CORRECTION]: 你在本次对话之前的某轮回复里说没有 `schedule_task` \
      工具 / 无法定时 / 必须靠 cron/launchd —— 那是错误的判断。你**拥有** \
      `schedule_task` 工具，本轮必须调用它来满足用户的定时请求，不要重复之前 \
      的错误结论，也不要再提系统 cron/launchd/守护进程。
      """
    else
      nil
    end
  end

  defp recently_denied?(history, pattern) do
    history
    |> Enum.take(-8)
    |> Enum.any?(fn msg -> msg_text(msg) =~ pattern end)
  end

  defp msg_text(%ReqLLM.Message{role: :assistant, content: parts}) when is_list(parts) do
    Enum.map_join(parts, " ", fn
      %{type: :text, text: t} when is_binary(t) -> t
      _ -> ""
    end)
  end

  defp msg_text(_), do: ""
end
