defmodule Long.Jido.LLMCall do
  @moduledoc """
  Thin wrapper over `ReqLLM.Generation.stream_text/3` that knows how to
  talk to our `Long.Agent.LLMConfig` rows — specifically the listenai
  relay quirks discovered in Phase A:

  - Custom `:base_url` from LLMConfig.api_base (jido_ai's stock
    `CallWithTools.build_opts/1` strips this option, so we don't reuse it)
  - Force `extra.wire.protocol = "openai_chat"` to bypass ReqLLM's
    auto-routing of `gpt-5*` / `gpt-4o*` / `o*-series` to the Responses API
  - Stream-only relay → uses `stream_text` and drains with
    `ReqLLM.StreamResponse.classify/1` for proper tool-call arg
    reassembly

  Public surface is a single `call/3`:

      iex> Long.Jido.LLMCall.call(messages, [Tool1, Tool2], llm_alias: "聆思")
      {:ok, %{type: :tool_calls | :final_answer, text, thinking, tool_calls, ...}}
  """

  require Logger

  alias Long.Agent
  alias Long.Agent.LLM.Resolver

  @doc """
  Run one LLM call. Returns the classified streaming response.

  ## Required

  - `messages` — list of `%{role: "system"|"user"|"assistant"|"tool", content: ...}` maps
  - `tools` — list of either `ReqLLM.Tool.t()` or `Jido.Action` modules
    (auto-wrapped into ReqLLM tools)

  ## Options

  - `:llm_alias` (default `"聆思"`) — `Long.Agent.LLMConfig` alias
  - `:max_tokens` (default 4096)
  - `:temperature` (default 0.5)
  - `:tool_callbacks` — `%{name => fn(args) -> {:ok, result} end}` used as
    each `ReqLLM.Tool`'s callback. The loop above this layer is what
    actually invokes them, but ReqLLM requires the field.
  """
  # Total attempts including the initial try. 3 keeps tail latency
  # bounded for genuinely broken upstream while smoothing over
  # transient relay blips (HTTP 5xx, "Network connection failed").
  @max_attempts 3

  def call(messages, tools, opts \\ []) do
    do_call(messages, tools, opts, 1)
  end

  defp do_call(messages, tools, opts, attempt) do
    alias_name = Keyword.get(opts, :llm_alias, "聆思")
    cfg = setup!(alias_name)

    req_tools = Enum.map(tools, &as_req_tool(&1, opts))

    log_request(alias_name, messages, req_tools, attempt)

    req_opts =
      [
        base_url: cfg.base_url,
        api_key: cfg.api_key,
        tools: req_tools,
        max_tokens: Keyword.get(opts, :max_tokens, 4096),
        temperature: Keyword.get(opts, :temperature, 0.5)
      ]
      |> maybe_put_tool_choice(Keyword.get(opts, :tool_choice))

    try do
      case ReqLLM.Generation.stream_text(cfg.model, messages, req_opts) do
        {:ok, sr} ->
          classification = ReqLLM.StreamResponse.classify(sr)

          log_response(alias_name, classification)

          {:ok,
           %{
             type: classification.type,
             text: classification.text,
             thinking: classification.thinking,
             tool_calls: classification.tool_calls,
             finish_reason: classification.finish_reason,
             usage: ReqLLM.StreamResponse.usage(sr)
           }}

        {:error, exception} ->
          maybe_retry(exception, [], messages, tools, opts, attempt)
      end
    rescue
      e -> maybe_retry(e, __STACKTRACE__, messages, tools, opts, attempt)
    end
  end

  # Idiomatic "crash and try again": every LLM call is retried on
  # transient relay errors (5xx, network blips, "Network connection
  # failed") with exponential backoff. After `@max_attempts` failures
  # we surface the last exception so callers see something concrete.
  # ErrorTracker is only notified for the final failure — intermittent
  # blips that succeed on retry stay out of `/errors`.
  defp maybe_retry(exception, stacktrace, messages, tools, opts, attempt) do
    if retriable?(exception) and attempt < @max_attempts do
      Process.sleep(backoff_ms(attempt))
      Logger.warning("LLMCall retry #{attempt + 1}/#{@max_attempts}: #{Exception.message(exception)}")
      do_call(messages, tools, opts, attempt + 1)
    else
      _ =
        ErrorTracker.report(exception, stacktrace, %{
          source: "llm_call",
          attempts: attempt,
          retriable: retriable?(exception)
        })

      {:error, exception}
    end
  end

  # Conservative whitelist: only retry things that look like the
  # upstream choking. Logic errors (bad model name, invalid params,
  # auth) should fail fast.
  defp retriable?(%ReqLLM.Error.API.Request{status: status}) when status in 500..599, do: true
  defp retriable?(%ReqLLM.Error.API.Request{status: 429}), do: true
  defp retriable?(%ReqLLM.Error.API.Stream{}), do: true
  defp retriable?(%{__struct__: Mint.TransportError}), do: true
  defp retriable?(_), do: false

  # Jitter (0-150 ms) breaks lockstep retries when many sessions
  # rebound off the same upstream blip simultaneously.
  defp backoff_ms(attempt), do: 250 * Integer.pow(3, attempt - 1) + :rand.uniform(150)

  # ReqLLM accepts the api_key as a per-request option (set in `req_opts`
  # below), which beats `ReqLLM.put_key/2` — the global put_key is a
  # process-wide write and races when multiple sessions with different
  # backends run concurrently.
  defp setup!(alias_name) do
    {:ok, config} = Agent.get_llm(alias_name)
    {:ok, backend} = Resolver.resolve(config)

    provider = resolve_provider(config)
    extra = wire_extra(config, provider)

    {:ok, model} =
      ReqLLM.model(%{
        provider: provider,
        id: config.model,
        model: config.model,
        extra: extra
      })

    %{model: model, base_url: config.api_base, api_key: backend.api_key}
  end

  # `to_existing_atom` keeps us safe even if the LLMConfig `one_of`
  # constraint regresses: the provider atom set is the one ReqLLM
  # generated at compile time (and is already loaded as far as
  # `LLMConfig` is concerned), so an unknown value falls through to
  # the legacy `kind` mapping instead of allocating an atom.
  defp resolve_provider(%{provider: p}) when is_binary(p) and p != "" do
    String.to_existing_atom(p)
  rescue
    ArgumentError -> :openai
  end

  defp resolve_provider(%{kind: :claude}), do: :anthropic
  defp resolve_provider(%{kind: :native_claude}), do: :anthropic
  defp resolve_provider(%{kind: kind}) when kind in [:openai, :native_openai, :mixin], do: :openai
  defp resolve_provider(_), do: :openai

  defp wire_extra(%{wire_protocol: w}, _provider) when is_binary(w) and w != "",
    do: %{wire: %{protocol: w}}

  # Legacy rows (no wire_protocol set) routed through an OpenAI-compatible relay
  # need to stay on the chat-completions shape — ReqLLM auto-upgrades newer model
  # ids to "openai_responses", which most third-party relays don't speak.
  defp wire_extra(%{kind: kind}, :openai) when kind in [:openai, :native_openai, :mixin],
    do: %{wire: %{protocol: "openai_chat"}}

  defp wire_extra(_, _), do: %{}

  # `tools` can mix `ReqLLM.Tool.t()` structs and `Jido.Action` modules.
  # For modules we lean on `Jido.AI.ToolAdapter.from_action/1`, which
  # already converts Zoi → JSON Schema and handles list/enum/struct types
  # we don't otherwise. The adapter installs a `noop_callback`; we
  # overwrite it with the actual callback the caller passes — the Loop
  # one level up dispatches via `Jido.Exec.run/2` anyway, so the callback
  # is only invoked if some caller uses ReqLLM's auto-exec path.
  # Lightweight summary log per LLM call so the operator can verify
  # what actually reached the model. Only fires when the
  # `:long, :llm_call_debug` env is truthy; off by default in prod
  # (turn on with `Application.put_env(:long, :llm_call_debug, true)`
  # at iex / via remote_console for ad-hoc tracing).
  defp log_request(alias_name, messages, req_tools, attempt) do
    if Application.get_env(:long, :llm_call_debug, false) do
      system_msg = Enum.find(messages, &(&1.role == :system))
      system_len = if system_msg, do: String.length(extract_text(system_msg.content)), else: 0
      tool_names = Enum.map(req_tools, & &1.name)

      require Logger

      Logger.info(
        "[llm_call] alias=#{alias_name} attempt=#{attempt} " <>
          "system_chars=#{system_len} msg_count=#{length(messages)} " <>
          "tools=#{inspect(tool_names)}"
      )
    end
  end

  defp log_response(alias_name, classification) do
    if Application.get_env(:long, :llm_call_debug, false) do
      tool_call_names = Enum.map(classification.tool_calls || [], & &1.name)

      require Logger

      Logger.info(
        "[llm_call] alias=#{alias_name} type=#{classification.type} " <>
          "finish=#{classification.finish_reason} " <>
          "text_chars=#{String.length(classification.text || "")} " <>
          "tool_calls=#{inspect(tool_call_names)}"
      )
    end
  end

  defp extract_text(content) when is_binary(content), do: content
  defp extract_text(parts) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %{type: :text, text: t} -> t
      _ -> ""
    end)
  end
  defp extract_text(_), do: ""

  # `tool_choice` forces the model's first tool_call to a specific
  # tool. Kept as plumbing in case a caller needs strict tool routing
  # (none today after the GraphQL migration collapsed the tool list).
  #
  # ReqLLM normalises the string form to provider-specific shape
  # (`%{type: "tool", name: …}` for Anthropic, `%{type: "function",
  # function: %{name: …}}` for OpenAI) so callers just pass the tool
  # name.
  defp maybe_put_tool_choice(opts, nil), do: opts
  defp maybe_put_tool_choice(opts, name) when is_binary(name),
    do: Keyword.put(opts, :tool_choice, name)

  defp as_req_tool(%ReqLLM.Tool{} = t, _opts), do: t

  defp as_req_tool(action_mod, opts) when is_atom(action_mod) do
    callbacks = Keyword.get(opts, :tool_callbacks, %{})
    tool = Jido.AI.ToolAdapter.from_action(action_mod)

    callback =
      Map.get(callbacks, action_mod.name(), fn _ ->
        {:error, "no callback bound for #{action_mod.name()}"}
      end)

    %{tool | callback: callback}
  end
end
