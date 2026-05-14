defmodule Long.Agent.LLMTest.Stubbed do
  @moduledoc false
  @behaviour Long.Agent.LLM.Backend

  defstruct [:inner, :plug]

  @impl true
  def stream_chat(%__MODULE__{inner: %mod{} = b, plug: p}, messages, opts) do
    mod.stream_chat(b, messages, Keyword.put(opts, :plug, p))
  end
end

defmodule Long.Agent.LLMTest do
  use Long.DataCase, async: false
  import Plug.Conn

  alias Long.Agent
  alias Long.Agent.LLM
  alias Long.Agent.LLM.{Format, Response, SSE, Temperature, Tool, URL}
  alias Long.Agent.LLM.Backend.{Claude, Mixin, OpenAI}

  doctest Long.Agent.LLM.URL

  describe "URL.join/2" do
    test "auto-appends /v1 + path for bare hosts" do
      assert URL.join("http://h:2001", "chat/completions") == "http://h:2001/v1/chat/completions"
    end

    test "respects /vN prefix" do
      assert URL.join("http://h/v2", "chat/completions") == "http://h/v2/chat/completions"
    end

    test "leaves a path that already ends with the suffix alone" do
      assert URL.join("https://x/v1/messages", "messages") == "https://x/v1/messages"
    end

    test "strips trailing $ marker" do
      assert URL.join("https://x/raw$", "messages") == "https://x/raw"
    end
  end

  describe "Temperature.normalize/2" do
    test "kimi/moonshot forced to 1.0" do
      assert Temperature.normalize(0.3, "kimi-k2") == 1.0
      assert Temperature.normalize(0.3, "moonshot-v1") == 1.0
    end

    test "minimax clamped to (0, 1]" do
      assert Temperature.normalize(2.0, "MiniMax-M2.7") == 1.0
      assert Temperature.normalize(0.0, "MiniMax-M2.7") == 0.01
    end

    test "passthrough for others" do
      assert Temperature.normalize(0.7, "gpt-5.4") == 0.7
    end
  end

  describe "Format.to_claude_messages/1" do
    test "wraps string content into a text block" do
      [m] = Format.to_claude_messages([%{role: :user, content: "hi"}])
      assert m.content == [%{type: :text, text: "hi"}]
    end

    test "merges adjacent same-role messages" do
      [merged] =
        Format.to_claude_messages([
          %{role: :user, content: "a"},
          %{role: :user, content: "b"}
        ])

      assert Enum.map(merged.content, & &1.text) == ["a", "\n", "b"]
    end

    test "drops leading non-user messages" do
      result =
        Format.to_claude_messages([
          %{role: :assistant, content: "leftover"},
          %{role: :user, content: "real"}
        ])

      assert length(result) == 1
      assert hd(result).role == :user
    end

    test "synthesizes tool_result blocks for missing tool_uses" do
      result =
        Format.to_claude_messages([
          %{role: :user, content: "go"},
          %{
            role: :assistant,
            content: [%{type: :tool_use, id: "t1", name: "ping", input: %{}}]
          },
          %{role: :user, content: "next"}
        ])

      user_after = List.last(result)
      synth = Enum.find(user_after.content, &(&1[:type] == :tool_result))
      assert synth.tool_use_id == "t1"
      assert synth.content == "(error)"
    end
  end

  describe "Format.to_openai_messages/1" do
    test "converts assistant tool_use into tool_calls" do
      [_user, asst] =
        Format.to_openai_messages([
          %{role: :user, content: "go"},
          %{
            role: :assistant,
            content: [
              %{type: :text, text: "calling"},
              %{type: :tool_use, id: "t1", name: "ping", input: %{"a" => 1}}
            ]
          }
        ])

      assert asst["role"] == "assistant"

      assert [%{"id" => "t1", "function" => %{"name" => "ping", "arguments" => args}}] =
               asst["tool_calls"]

      assert Jason.decode!(args) == %{"a" => 1}
    end

    test "tool_result block becomes a separate tool role message" do
      msgs =
        Format.to_openai_messages([
          %{role: :user, content: "go"},
          %{role: :assistant, content: [%{type: :tool_use, id: "t1", name: "ping", input: %{}}]},
          %{role: :user, content: [%{type: :tool_result, tool_use_id: "t1", content: "pong"}]}
        ])

      tail = List.last(msgs)
      assert tail["role"] == "tool"
      assert tail["tool_call_id"] == "t1"
      assert tail["content"] == "pong"
    end
  end

  describe "Content + Response" do
    test "Response.from_blocks/2 extracts text, thinking, tool calls and sets stop reason" do
      blocks = [
        %{type: :thinking, thinking: "let me see", signature: ""},
        %{type: :text, text: "Hi"},
        %{type: :tool_use, id: "t1", name: "ping", input: %{"x" => 1}}
      ]

      resp = Response.from_blocks(blocks)
      assert resp.content == "Hi"
      assert resp.thinking == "let me see"
      assert [%{id: "t1", name: "ping", input: %{"x" => 1}}] = resp.tool_calls
      assert resp.stop_reason == :tool_use
    end

    test "Tool.to_openai/to_claude shape" do
      t = %Tool{name: "ping", description: "p", input_schema: %{"type" => "object"}}
      oai = Tool.to_openai(t)
      assert oai["type"] == "function"
      assert oai["function"]["name"] == "ping"
      claude = Tool.to_claude(t)
      assert claude["name"] == "ping"
      assert claude["input_schema"]["type"] == "object"
    end
  end

  describe "SSE.parse_claude/2" do
    test "accumulates text deltas and emits :done with structured response" do
      events = ~s(
data: {"type":"message_start","message":{"model":"claude-opus-4-7","usage":{"input_tokens":10}}}

data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}

data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello "}}

data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}

data: {"type":"content_block_stop","index":0}

data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

data: {"type":"message_stop"}

)

      {events, _state, leftover} = SSE.parse_claude(events, SSE.claude_init_state())

      texts =
        events
        |> Enum.filter(&match?({:text_delta, _}, &1))
        |> Enum.map(&elem(&1, 1))

      assert Enum.join(texts) == "Hello world"
      assert leftover == ""

      {:done, %Response{content: "Hello world", stop_reason: :end_turn, model: "claude-opus-4-7"}} =
        List.last(events)
    end

    test "tool_use_delta accumulates partial JSON and parses on stop" do
      lines = ~s(
data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"ping"}}

data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"a\\":"}}

data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"1}"}}

data: {"type":"content_block_stop","index":0}

data: {"type":"message_stop"}

)

      {events, _state, _} = SSE.parse_claude(lines, SSE.claude_init_state())
      assert Enum.any?(events, &match?({:tool_use_start, %{id: "t1", name: "ping"}}, &1))
      assert Enum.any?(events, &match?({:tool_use_done, %{input: %{"a" => 1}}}, &1))

      {:done,
       %Response{tool_calls: [%{name: "ping", input: %{"a" => 1}}], stop_reason: :tool_use}} =
        List.last(events)
    end

    test "handles partial-buffer boundaries" do
      payload =
        ~s(data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}\n\n) <>
          ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"abc"}}\n\n)

      # Feed it byte-by-byte and verify accumulator works
      state = SSE.claude_init_state()

      {all_events, final_state} =
        payload
        |> :binary.bin_to_list()
        |> Enum.chunk_every(7)
        |> Enum.reduce({[], {state, ""}}, fn chunk, {evs, {st, buf}} ->
          new_buf = buf <> List.to_string(chunk)
          {events, new_st, leftover} = SSE.parse_claude(new_buf, st)
          {evs ++ events, {new_st, leftover}}
        end)

      texts = Enum.filter(all_events, &match?({:text_delta, _}, &1))
      assert Enum.map(texts, &elem(&1, 1)) |> Enum.join() == "abc"
      assert {state, _leftover} = final_state
      assert is_map(state)
    end
  end

  describe "SSE.parse_openai/2" do
    test "streams content deltas and tool calls" do
      lines = ~s(
data: {"choices":[{"delta":{"content":"Hi"},"index":0}],"model":"gpt-5.4"}

data: {"choices":[{"delta":{"content":" there"},"index":0}]}

data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"t1","function":{"name":"ping","arguments":"{\\"x\\":1}"}}]},"index":0}]}

data: {"choices":[{"delta":{},"index":0,"finish_reason":"tool_calls"}]}

data: [DONE]

)

      {events, _state, _} = SSE.parse_openai(lines, SSE.openai_init_state())

      texts =
        events
        |> Enum.filter(&match?({:text_delta, _}, &1))
        |> Enum.map(&elem(&1, 1))
        |> Enum.join()

      assert texts == "Hi there"

      {:done,
       %Response{
         content: "Hi there",
         tool_calls: [%{name: "ping", input: %{"x" => 1}}],
         stop_reason: :tool_use
       }} =
        List.last(events)
    end
  end

  describe "Claude backend end-to-end (inline plug)" do
    test "streams a full response through StreamRunner" do
      body = """
      data: {"type":"message_start","message":{"model":"claude-opus-4-7","usage":{"input_tokens":3}}}\n\n
      data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}\n\n
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}\n\n
      data: {"type":"content_block_stop","index":0}\n\n
      data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\n
      data: {"type":"message_stop"}\n\n
      """

      plug = fn conn ->
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_resp(200, body)
      end

      backend = %Claude{
        name: "test",
        model: "claude-opus-4-7",
        api_base: "http://test.local",
        api_key: "sk-ant-test",
        stream?: true
      }

      events = LLM.chat(backend, [%{role: :user, content: "hi"}], plug: plug) |> Enum.to_list()

      text =
        events
        |> Enum.filter(&match?({:text_delta, _}, &1))
        |> Enum.map(&elem(&1, 1))
        |> Enum.join()

      assert text == "ok"
      assert {:done, %Response{content: "ok", stop_reason: :end_turn}} = List.last(events)
    end
  end

  describe "OpenAI backend end-to-end (inline plug)" do
    test "streams through chat/completions" do
      body = """
      data: {"choices":[{"delta":{"content":"yo"},"index":0}],"model":"gpt-5.4"}\n\n
      data: {"choices":[{"delta":{},"index":0,"finish_reason":"stop"}]}\n\n
      data: [DONE]\n\n
      """

      plug = fn conn ->
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_resp(200, body)
      end

      backend = %OpenAI{
        name: "oai-test",
        model: "gpt-5.4",
        api_base: "http://test.local/v1",
        api_key: "sk-test"
      }

      events = LLM.chat(backend, [%{role: :user, content: "hi"}], plug: plug) |> Enum.to_list()
      assert {:done, %Response{content: "yo"}} = List.last(events)
    end
  end

  describe "Mixin failover" do
    test "advances to second member when the first errors" do
      primary_plug = fn conn -> send_resp(conn, 500, "boom") end

      secondary_plug = fn conn ->
        body = """
        data: {"choices":[{"delta":{"content":"backup"},"index":0}],"model":"gpt-5.4"}\n\n
        data: {"choices":[{"delta":{},"index":0,"finish_reason":"stop"}]}\n\n
        data: [DONE]\n\n
        """

        conn
        |> put_resp_content_type("text/event-stream")
        |> send_resp(200, body)
      end

      primary =
        wrap_with_plug(primary_plug, %OpenAI{
          name: "p",
          model: "gpt-5.4",
          api_base: "http://test.local/v1",
          api_key: "k"
        })

      secondary =
        wrap_with_plug(secondary_plug, %OpenAI{
          name: "s",
          model: "gpt-5.4",
          api_base: "http://test.local/v1",
          api_key: "k"
        })

      mixin = %Mixin{
        name: "mix",
        members: [primary, secondary],
        max_retries: 3,
        base_delay_ms: 1
      }

      events = LLM.chat(mixin, [%{role: :user, content: "hi"}], []) |> Enum.to_list()
      assert {:done, %Response{content: "backup"}} = List.last(events)
    end
  end

  describe "Resolver" do
    setup do
      System.put_env("LONG_LLM_TEST_KEY", "test-key-xyz")
      on_exit(fn -> System.delete_env("LONG_LLM_TEST_KEY") end)
      :ok
    end

    test "resolves a Claude config from DB" do
      {:ok, _} =
        Agent.register_llm(%{
          alias: "test-claude",
          kind: :claude,
          model: "claude-opus-4-7",
          api_base: "https://api.anthropic.com",
          api_key_env_var: "LONG_LLM_TEST_KEY",
          params: %{
            "max_tokens" => 4096,
            "thinking_type" => "adaptive",
            "fake_cc_system_prompt?" => true
          }
        })

      assert {:ok, %Claude{} = b} = LLM.resolve("test-claude")
      assert b.api_key == "test-key-xyz"
      assert b.max_tokens == 4096
      assert b.thinking_type == :adaptive
      assert b.fake_cc_system_prompt? == true
    end

    test "missing env var produces a clean error" do
      {:ok, _} =
        Agent.register_llm(%{
          alias: "broken",
          kind: :claude,
          model: "claude",
          api_base: "https://x",
          api_key_env_var: "DEFINITELY_NOT_SET_#{System.unique_integer()}"
        })

      assert {:error, {:env_var_unset, _}} = LLM.resolve("broken")
    end
  end

  defp wrap_with_plug(plug, backend) do
    %Long.Agent.LLMTest.Stubbed{inner: backend, plug: plug}
  end
end
