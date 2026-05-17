defmodule Long.Agent.IntentRouterTest do
  use ExUnit.Case, async: true

  alias Long.Agent.IntentRouter

  defmodule FakeTool do
    def name, do: "schedule_task"
  end

  defmodule OtherTool do
    def name, do: "memory_remember"
  end

  describe "schedule intent" do
    test "fires on '每天晚上7点帮我...'" do
      r = IntentRouter.classify("每天晚上7点帮我填工时", [FakeTool], [])
      assert r.tool_choice == "schedule_task"
    end

    test "fires on '定时'" do
      r = IntentRouter.classify("帮我定时跑这个脚本", [FakeTool], [])
      assert r.tool_choice == "schedule_task"
    end

    test "fires on 'cron'" do
      r = IntentRouter.classify("用 cron 跑一下", [FakeTool], [])
      assert r.tool_choice == "schedule_task"
    end

    test "fires on '每小时'" do
      r = IntentRouter.classify("每 2 小时拉一次新闻", [FakeTool], [])
      assert r.tool_choice == "schedule_task"
    end

    test "does NOT fire on incidental '每天'" do
      r = IntentRouter.classify("我每天都很忙", [FakeTool], [])
      assert r.tool_choice == nil
    end

    test "does NOT fire when schedule_task isn't in the tool list" do
      r = IntentRouter.classify("每天晚上7点帮我填工时", [OtherTool], [])
      assert r.tool_choice == nil
    end
  end

  describe "anti-pollution correction" do
    test "adds correction when history contains a recent denial" do
      polluted_history = [
        %ReqLLM.Message{role: :user, content: [%{type: :text, text: "每天帮我"}]},
        %ReqLLM.Message{
          role: :assistant,
          content: [%{type: :text, text: "我没有内置的定时器工具"}]
        }
      ]

      r = IntentRouter.classify("每天晚上7点帮我填工时", [FakeTool], polluted_history)
      assert r.tool_choice == "schedule_task"
      assert r.system_correction =~ "拥有"
      assert r.system_correction =~ "schedule_task"
    end

    test "skips correction when history is clean" do
      clean_history = [
        %ReqLLM.Message{role: :user, content: [%{type: :text, text: "hi"}]},
        %ReqLLM.Message{role: :assistant, content: [%{type: :text, text: "Hi back"}]}
      ]

      r = IntentRouter.classify("每天晚上7点帮我填工时", [FakeTool], clean_history)
      assert r.tool_choice == "schedule_task"
      assert r.system_correction == nil
    end
  end

  describe "no intent" do
    test "returns nil/nil for general chat" do
      r = IntentRouter.classify("你好,讲个笑话吧", [FakeTool], [])
      assert r == %{tool_choice: nil, system_correction: nil}
    end
  end
end
