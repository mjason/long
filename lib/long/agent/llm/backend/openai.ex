defmodule Long.Agent.LLM.Backend.OpenAI do
  @moduledoc """
  OpenAI chat/completions backend, port of `NativeOAISession` (chat_completions
  mode). Handles:

  - Bearer auth
  - Provider-specific temperature normalization (Kimi/Moonshot → 1.0, MiniMax
    clamped to (0, 1])
  - GPT-5/o-series use `max_completion_tokens` instead of `max_tokens`
  - SSE streaming (`stream_options: {include_usage: true}`)
  - Tool calls via native `tools` field
  - Cache markers (`cache_control: ephemeral`) auto-stamped on last 2 user
    messages when the model name contains "claude" or "anthropic"
  """

  @behaviour Long.Agent.LLM.Backend

  alias Long.Agent.LLM.{Format, SSE, StreamRunner, Temperature, Tool, URL}

  defstruct [
    :name,
    :model,
    :api_base,
    :api_key,
    :proxy,
    max_tokens: 8192,
    temperature: 1.0,
    stream?: true,
    max_retries: 1,
    connect_timeout: 5_000,
    receive_timeout: 30_000,
    reasoning_effort: nil,
    context_win: 24_000,
    service_tier: nil
  ]

  @impl true
  def stream_chat(%__MODULE__{} = backend, messages, opts \\ []) do
    messages = build_oai_messages(messages, opts[:system], backend.model)
    tools = Keyword.get(opts, :tools, [])

    payload =
      %{
        "model" => backend.model,
        "messages" => messages,
        "stream" => backend.stream?
      }
      |> maybe_put_stream_options(backend.stream?)
      |> maybe_put_temp(backend.temperature, backend.model)
      |> maybe_put_max_tokens(backend.max_tokens, backend.model)
      |> maybe_put_reasoning_effort(backend.reasoning_effort)
      |> maybe_put_tools(tools)
      |> maybe_put_service_tier(backend.service_tier)

    headers = [
      {"authorization", "Bearer #{backend.api_key}"},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]

    url = URL.join(backend.api_base, "chat/completions")

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
      SSE.openai_init_state(),
      &SSE.parse_openai/2,
      receive_timeout: backend.receive_timeout + 5_000
    )
  end

  defp build_oai_messages(messages, system, model) do
    oai_messages = Format.to_openai_messages(messages)

    oai_messages =
      if system in [nil, ""],
        do: oai_messages,
        else: [%{"role" => "system", "content" => system} | oai_messages]

    stamp_oai_cache_markers(oai_messages, model)
  end

  defp stamp_oai_cache_markers(messages, model) do
    ml = String.downcase(model || "")

    if String.contains?(ml, "claude") or String.contains?(ml, "anthropic") do
      user_idxs = for {%{"role" => "user"}, i} <- Enum.with_index(messages), do: i
      last_two = MapSet.new(Enum.take(user_idxs, -2))

      Enum.with_index(messages, fn msg, i ->
        if MapSet.member?(last_two, i), do: add_cache_to_last(msg), else: msg
      end)
    else
      messages
    end
  end

  defp add_cache_to_last(%{"content" => c} = msg) when is_binary(c) do
    %{
      msg
      | "content" => [
          %{"type" => "text", "text" => c, "cache_control" => %{"type" => "ephemeral"}}
        ]
    }
  end

  defp add_cache_to_last(%{"content" => parts} = msg) when is_list(parts) and parts != [] do
    {leading, [last]} = Enum.split(parts, length(parts) - 1)
    %{msg | "content" => leading ++ [Map.put(last, "cache_control", %{"type" => "ephemeral"})]}
  end

  defp add_cache_to_last(msg), do: msg

  defp maybe_put_stream_options(payload, true),
    do: Map.put(payload, "stream_options", %{"include_usage" => true})

  defp maybe_put_stream_options(payload, _), do: payload

  defp maybe_put_temp(payload, t, model) do
    normalized = Temperature.normalize(t, model || "")

    if normalized == 1.0, do: payload, else: Map.put(payload, "temperature", normalized)
  end

  defp maybe_put_max_tokens(payload, nil, _), do: payload

  defp maybe_put_max_tokens(payload, tokens, model) when is_binary(model) do
    key =
      if String.match?(String.downcase(model), ~r/^(gpt-5|o1|o2|o3|o4)/),
        do: "max_completion_tokens",
        else: "max_tokens"

    Map.put(payload, key, tokens)
  end

  defp maybe_put_max_tokens(payload, tokens, _), do: Map.put(payload, "max_tokens", tokens)

  defp maybe_put_reasoning_effort(payload, nil), do: payload

  defp maybe_put_reasoning_effort(payload, effort)
       when effort in [:none, :minimal, :low, :medium, :high, :xhigh] do
    Map.put(payload, "reasoning_effort", Atom.to_string(effort))
  end

  defp maybe_put_reasoning_effort(payload, _), do: payload

  defp maybe_put_tools(payload, []), do: payload

  defp maybe_put_tools(payload, tools) do
    Map.put(payload, "tools", Enum.map(tools, &tool_to_oai/1))
  end

  defp tool_to_oai(%Tool{} = t), do: Tool.to_openai(t)
  defp tool_to_oai(%{} = m), do: m

  defp maybe_put_service_tier(payload, nil), do: payload

  defp maybe_put_service_tier(payload, tier),
    do: Map.put(payload, "service_tier", Atom.to_string(tier))

  defp maybe_add_test_stub(req_opts, opts) do
    cond do
      plug = Keyword.get(opts, :plug) -> Keyword.put(req_opts, :plug, plug)
      stub = Keyword.get(opts, :req_test_stub) -> Keyword.put(req_opts, :plug, {Req.Test, stub})
      true -> req_opts
    end
  end
end
