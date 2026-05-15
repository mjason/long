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
  def call(messages, tools, opts \\ []) do
    alias_name = Keyword.get(opts, :llm_alias, "聆思")
    cfg = setup!(alias_name)

    req_tools = Enum.map(tools, &as_req_tool(&1, opts))

    req_opts = [
      base_url: cfg.base_url,
      api_key: cfg.api_key,
      tools: req_tools,
      max_tokens: Keyword.get(opts, :max_tokens, 4096),
      temperature: Keyword.get(opts, :temperature, 0.5)
    ]

    with {:ok, %ReqLLM.StreamResponse{} = sr} <-
           ReqLLM.Generation.stream_text(cfg.model, messages, req_opts) do
      classify_stream(sr)
    end
  end

  # `ReqLLM.StreamResponse.classify/1` drains the SSE stream lazily and
  # raises on transport errors mid-flight (e.g. relay returning 500 after
  # the connection upgrade). Normalize that into `{:error, _}` so callers
  # — Summarizer, Loop, History.maybe_compress — can pattern-match
  # instead of crashing the whole session task.
  defp classify_stream(sr) do
    try do
      classification = ReqLLM.StreamResponse.classify(sr)

      {:ok,
       %{
         type: classification.type,
         text: classification.text,
         thinking: classification.thinking,
         tool_calls: classification.tool_calls,
         finish_reason: classification.finish_reason,
         usage: ReqLLM.StreamResponse.usage(sr)
       }}
    rescue
      e -> {:error, e}
    end
  end

  # ReqLLM accepts the api_key as a per-request option (set in `req_opts`
  # below), which beats `ReqLLM.put_key/2` — the global put_key is a
  # process-wide write and races when multiple sessions with different
  # backends run concurrently.
  defp setup!(alias_name) do
    {:ok, config} = Agent.get_llm(alias_name)
    {:ok, backend} = Resolver.resolve(config)

    {:ok, model} =
      ReqLLM.model(%{
        provider: :openai,
        id: config.model,
        model: config.model,
        extra: %{wire: %{protocol: "openai_chat"}}
      })

    %{model: model, base_url: config.api_base, api_key: backend.api_key}
  end

  # `tools` can mix `ReqLLM.Tool.t()` structs and `Jido.Action` modules.
  # For modules we lean on `Jido.AI.ToolAdapter.from_action/1`, which
  # already converts Zoi → JSON Schema and handles list/enum/struct types
  # we don't otherwise. The adapter installs a `noop_callback`; we
  # overwrite it with the actual callback the caller passes — the Loop
  # one level up dispatches via `Jido.Exec.run/2` anyway, so the callback
  # is only invoked if some caller uses ReqLLM's auto-exec path.
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
