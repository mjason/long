defmodule Long.Agent.DenoEnvTest do
  use ExUnit.Case, async: true

  alias Long.Agent.DenoEnv

  describe "member_inbox/2" do
    test "a bound member gets an inbox inside their own workspace" do
      assert DenoEnv.member_inbox("/ws", "abc") == "/ws/members/abc/inbox"
    end

    test "the inbox is under the member workspace, so code_run (sandboxed there) can reach it" do
      member = DenoEnv.workspace("/ws", "abc")
      inbox = DenoEnv.member_inbox("/ws", "abc")
      assert String.starts_with?(inbox, member <> "/")
    end

    test "a nil member yields nil so callers fall back to a shared inbox" do
      assert DenoEnv.member_inbox("/ws", nil) == nil
    end
  end
end
