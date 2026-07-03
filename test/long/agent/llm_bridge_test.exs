defmodule Long.Agent.LLMBridgeTest do
  use ExUnit.Case, async: true

  alias Long.Agent.LLMBridge

  describe "per-run token" do
    test "sign/verify round-trips the session id" do
      token = LLMBridge.sign("sess-123")
      assert {:ok, "sess-123"} = LLMBridge.verify(token)
    end

    test "deno_env injects a valid token + the loopback url" do
      env = LLMBridge.deno_env("sess-xyz")

      assert {~c"LONG_LLM_TOKEN", tok} = List.keyfind(env, ~c"LONG_LLM_TOKEN", 0)
      assert {~c"LONG_LLM_URL", url} = List.keyfind(env, ~c"LONG_LLM_URL", 0)
      assert {:ok, "sess-xyz"} = LLMBridge.verify(to_string(tok))
      assert to_string(url) =~ "127.0.0.1"
      assert to_string(url) =~ "/internal/llm"
    end

    test "deno_env is empty without a session (unbound/nil)" do
      assert LLMBridge.deno_env(nil) == []
      assert LLMBridge.deno_env("") == []
    end

    test "verify rejects missing / garbage tokens" do
      assert {:error, :missing} = LLMBridge.verify(nil)
      assert {:error, _} = LLMBridge.verify("not-a-real-token")
    end
  end

  describe "complete/2 request validation (no LLM call)" do
    test "empty request → :empty_prompt" do
      assert {:error, :empty_prompt} = LLMBridge.complete("sess-1", %{})
      assert {:error, :empty_prompt} = LLMBridge.complete("sess-1", %{"prompt" => ""})
      assert {:error, :empty_prompt} = LLMBridge.complete("sess-1", %{"messages" => []})
    end
  end
end
