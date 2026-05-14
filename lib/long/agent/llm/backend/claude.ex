defmodule Long.Agent.LLM.Backend.Claude do
  @moduledoc """
  Anthropic Messages API backend, port of `NativeClaudeSession`. Handles:

  - SSE streaming via `Long.Agent.LLM.StreamRunner`
  - Prompt-caching betas (always on; persistent cache for the CC system block,
    ephemeral cache on the last two user messages and the last tool definition)
  - `[1m]` model-name suffix → `context-1m-2025-08-07` beta header
  - CC fingerprint headers + `metadata.user_id` UUIDs, with optional injection of
    a custom system prompt into the first user message when talking to a relay
    that gates on the canonical Claude Code system text (`:fake_cc_system_prompt?`)
  - Authorization: `sk-ant-*` keys → `x-api-key`, otherwise `Authorization: Bearer`
  - `:thinking_type`, `:thinking_budget_tokens`, `:reasoning_effort`
  - Tool calls via API-native `tools` field (function calling)
  """

  @behaviour Long.Agent.LLM.Backend

  alias Long.Agent.LLM.{Format, SSE, StreamRunner, Tool, URL}

  defstruct [
    :name,
    :model,
    :api_base,
    :api_key,
    :proxy,
    fake_cc_system_prompt?: false,
    user_agent: "claude-cli/2.1.113 (external, cli)",
    max_tokens: 8192,
    temperature: 1.0,
    stream?: true,
    max_retries: 1,
    connect_timeout: 5_000,
    receive_timeout: 30_000,
    thinking_type: :adaptive,
    thinking_budget_tokens: nil,
    reasoning_effort: nil,
    context_win: 28_000
  ]

  @impl true
  def stream_chat(%__MODULE__{} = backend, messages, opts \\ []) do
    {model, beta_parts} = resolve_model_and_betas(backend.model)

    {wire_messages, system_blocks} =
      prepare_messages(messages, opts[:system], backend.fake_cc_system_prompt?)

    tools = Keyword.get(opts, :tools, [])

    payload =
      %{
        "model" => model,
        "max_tokens" => backend.max_tokens,
        "stream" => backend.stream?,
        "messages" => wire_messages,
        "system" => system_blocks,
        "metadata" => %{"user_id" => fake_user_id()}
      }
      |> maybe_put_temp(backend.temperature)
      |> apply_claude_thinking(backend)
      |> maybe_put_tools(tools)

    headers = build_headers(backend, beta_parts)
    url = URL.join(backend.api_base, "messages") <> "?beta=true"

    req_opts =
      [
        method: :post,
        url: url,
        headers: headers,
        json: payload,
        connect_options: [timeout: backend.connect_timeout],
        receive_timeout: backend.receive_timeout,
        retry: false
      ]
      |> maybe_add_test_stub(opts)

    StreamRunner.stream(
      req_opts,
      SSE.claude_init_state(),
      &SSE.parse_claude/2,
      receive_timeout: backend.receive_timeout + 5_000
    )
  end

  defp resolve_model_and_betas(model) when is_binary(model) do
    base_betas = [
      "claude-code-20250219",
      "interleaved-thinking-2025-05-14",
      "redact-thinking-2026-02-12",
      "prompt-caching-scope-2026-01-05"
    ]

    if String.match?(model, ~r/\[1m\]/i) do
      stripped = String.replace(model, ~r/\[1m\]/i, "")
      {stripped, List.insert_at(base_betas, 1, "context-1m-2025-08-07")}
    else
      {model, base_betas}
    end
  end

  defp prepare_messages(messages, system, fake_cc?) do
    normalized =
      messages
      |> Format.to_claude_messages()
      |> stamp_user_ephemeral_cache()

    cc_block = %{
      "type" => "text",
      "text" => "You are Claude Code, Anthropic's official CLI for Claude.",
      "cache_control" => %{"type" => "ephemeral"}
    }

    {normalized, system_blocks} =
      cond do
        system in [nil, ""] ->
          {normalized, [cc_block]}

        fake_cc? ->
          {inject_system_into_first_user(normalized, system), [cc_block]}

        true ->
          {normalized, [%{"type" => "text", "text" => system}]}
      end

    wire =
      Enum.map(normalized, fn m ->
        %{"role" => Atom.to_string(m.role), "content" => Enum.map(m.content, &block_to_wire/1)}
      end)

    {wire, system_blocks}
  end

  defp inject_system_into_first_user(messages, system) do
    case Enum.find_index(messages, &(&1.role == :user)) do
      nil ->
        [%{role: :user, content: [%{type: :text, text: system}]} | messages]

      idx ->
        List.update_at(messages, idx, fn msg ->
          %{msg | content: [%{type: :text, text: system} | msg.content]}
        end)
    end
  end

  defp stamp_user_ephemeral_cache(messages) do
    user_idxs = for {%{role: :user}, i} <- Enum.with_index(messages), do: i
    last_two = MapSet.new(Enum.take(user_idxs, -2))

    Enum.with_index(messages, fn msg, i ->
      if MapSet.member?(last_two, i) and msg.content != [] do
        {leading, [last]} = Enum.split(msg.content, length(msg.content) - 1)
        %{msg | content: leading ++ [Map.put(last, :cache_control, %{"type" => "ephemeral"})]}
      else
        msg
      end
    end)
  end

  defp block_to_wire(%{type: type} = block) do
    base = %{"type" => Atom.to_string(type)}

    Enum.reduce(block, base, fn
      {:type, _}, acc -> acc
      {:cache_control, v}, acc -> Map.put(acc, "cache_control", v)
      {k, v}, acc when is_atom(k) -> Map.put(acc, Atom.to_string(k), v)
      _, acc -> acc
    end)
  end

  defp build_headers(%__MODULE__{api_key: key, user_agent: ua}, beta_parts) do
    base = [
      {"content-type", "application/json"},
      {"anthropic-version", "2023-06-01"},
      {"anthropic-beta", Enum.join(beta_parts, ",")},
      {"anthropic-dangerous-direct-browser-access", "true"},
      {"user-agent", ua},
      {"x-app", "cli"}
    ]

    auth =
      if String.starts_with?(key || "", "sk-ant-") do
        {"x-api-key", key}
      else
        {"authorization", "Bearer #{key}"}
      end

    [auth | base]
  end

  defp maybe_put_temp(payload, 1.0), do: payload
  defp maybe_put_temp(payload, t), do: Map.put(payload, "temperature", t)

  defp apply_claude_thinking(payload, %__MODULE__{thinking_type: nil} = b),
    do: apply_reasoning_effort(payload, b.reasoning_effort)

  defp apply_claude_thinking(
         payload,
         %__MODULE__{thinking_type: :enabled, thinking_budget_tokens: budget} = b
       )
       when is_integer(budget) do
    payload
    |> Map.put("thinking", %{"type" => "enabled", "budget_tokens" => budget})
    |> apply_reasoning_effort(b.reasoning_effort)
  end

  defp apply_claude_thinking(payload, %__MODULE__{thinking_type: type} = b) do
    payload
    |> Map.put("thinking", %{"type" => Atom.to_string(type)})
    |> apply_reasoning_effort(b.reasoning_effort)
  end

  defp apply_reasoning_effort(payload, nil), do: payload

  defp apply_reasoning_effort(payload, effort) when effort in [:low, :medium, :high],
    do: Map.put(payload, "output_config", %{"effort" => Atom.to_string(effort)})

  defp apply_reasoning_effort(payload, :xhigh),
    do: Map.put(payload, "output_config", %{"effort" => "max"})

  defp apply_reasoning_effort(payload, _), do: payload

  defp maybe_put_tools(payload, []), do: payload

  defp maybe_put_tools(payload, tools) do
    claude_tools = Enum.map(tools, &tool_to_claude/1)
    last_idx = length(claude_tools) - 1

    claude_tools =
      List.update_at(
        claude_tools,
        last_idx,
        &Map.put(&1, "cache_control", %{"type" => "ephemeral"})
      )

    Map.put(payload, "tools", claude_tools)
  end

  defp tool_to_claude(%Tool{} = t), do: Tool.to_claude(t)
  defp tool_to_claude(%{} = m), do: m

  defp fake_user_id do
    Jason.encode!(%{
      "device_id" => :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
      "account_uuid" => Ecto.UUID.generate(),
      "session_id" => Ecto.UUID.generate()
    })
  end

  defp maybe_add_test_stub(req_opts, opts) do
    cond do
      plug = Keyword.get(opts, :plug) -> Keyword.put(req_opts, :plug, plug)
      stub = Keyword.get(opts, :req_test_stub) -> Keyword.put(req_opts, :plug, {Req.Test, stub})
      true -> req_opts
    end
  end
end
