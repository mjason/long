defmodule Long.Agent.LLM.Resolver do
  @moduledoc """
  Loads a backend struct from a `Long.Agent.LLMConfig` row. API keys come
  from `:api_key_env_var` (preferred — keeps secrets out of the DB) or
  fall back to the inline `:api_key` field for single-machine setups.
  """

  alias Long.Agent
  alias Long.Agent.LLM.Backend.{Claude, Mixin, OpenAI}

  def resolve!(name_or_id) do
    case resolve(name_or_id) do
      {:ok, backend} ->
        backend

      {:error, reason} ->
        raise "Long.Agent.LLM: cannot resolve #{inspect(name_or_id)}: #{inspect(reason)}"
    end
  end

  def resolve(alias_name) when is_binary(alias_name) do
    case Agent.get_llm(alias_name) do
      {:ok, config} -> build(config)
      {:error, e} -> {:error, e}
    end
  end

  def resolve(%Agent.LLMConfig{} = config), do: build(config)

  defp build(%Agent.LLMConfig{kind: :claude} = c) do
    with {:ok, key} <- fetch_key(c) do
      params = normalize_params(c.params || %{})

      backend = %Claude{
        name: c.alias,
        model: c.model,
        api_base: c.api_base,
        api_key: key,
        fake_cc_system_prompt?: Map.get(params, :fake_cc_system_prompt?, false),
        user_agent: Map.get(params, :user_agent, "claude-cli/2.1.113 (external, cli)"),
        max_tokens: Map.get(params, :max_tokens, 8192),
        temperature: Map.get(params, :temperature, 1.0),
        stream?: Map.get(params, :stream?, true),
        max_retries: Map.get(params, :max_retries, 1),
        connect_timeout: Map.get(params, :connect_timeout_ms, 5_000),
        receive_timeout: Map.get(params, :receive_timeout_ms, 30_000),
        thinking_type: Map.get(params, :thinking_type, :adaptive),
        thinking_budget_tokens: Map.get(params, :thinking_budget_tokens),
        reasoning_effort: Map.get(params, :reasoning_effort),
        context_win: Map.get(params, :context_win, 28_000)
      }

      {:ok, backend}
    end
  end

  defp build(%Agent.LLMConfig{kind: kind} = c) when kind in [:openai, :native_openai] do
    with {:ok, key} <- fetch_key(c) do
      params = normalize_params(c.params || %{})

      backend = %OpenAI{
        name: c.alias,
        model: c.model,
        api_base: c.api_base,
        api_key: key,
        max_tokens: Map.get(params, :max_tokens, 8192),
        temperature: Map.get(params, :temperature, 1.0),
        stream?: Map.get(params, :stream?, true),
        max_retries: Map.get(params, :max_retries, 1),
        connect_timeout: Map.get(params, :connect_timeout_ms, 5_000),
        receive_timeout: Map.get(params, :receive_timeout_ms, 30_000),
        reasoning_effort: Map.get(params, :reasoning_effort),
        context_win: Map.get(params, :context_win, 24_000),
        service_tier: Map.get(params, :service_tier)
      }

      {:ok, backend}
    end
  end

  defp build(%Agent.LLMConfig{kind: :native_claude} = c), do: build(%{c | kind: :claude})

  defp build(%Agent.LLMConfig{kind: :mixin} = c) do
    params = normalize_params(c.params || %{})
    member_aliases = Map.get(params, :members, [])

    with {:ok, members} <- resolve_members(member_aliases) do
      mixin = %Mixin{
        name: c.alias,
        members: members,
        max_retries: Map.get(params, :max_retries, 3),
        base_delay_ms: Map.get(params, :base_delay_ms, 500),
        spring_back_ms: Map.get(params, :spring_back_ms, 300_000)
      }

      {:ok, mixin}
    end
  end

  defp resolve_members(aliases) when is_list(aliases) do
    aliases
    |> Enum.reduce_while({:ok, []}, fn alias_name, {:ok, acc} ->
      case resolve(alias_name) do
        {:ok, b} -> {:cont, {:ok, acc ++ [b]}}
        {:error, e} -> {:halt, {:error, {:member_failed, alias_name, e}}}
      end
    end)
  end

  defp resolve_members(_), do: {:error, :invalid_members}

  defp fetch_key(%Agent.LLMConfig{api_key_env_var: var, api_key: key}) do
    cond do
      is_binary(var) and var != "" -> fetch_env(var)
      is_binary(key) and key != "" -> {:ok, key}
      true -> {:error, :no_credential}
    end
  end

  defp fetch_env(var) do
    case System.get_env(var) do
      nil -> {:error, {:env_var_unset, var}}
      "" -> {:error, {:env_var_blank, var}}
      key -> {:ok, key}
    end
  end

  defp normalize_params(params) when is_map(params) do
    Enum.into(params, %{}, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), normalize_value(k, v)}
      {k, v} when is_atom(k) -> {k, normalize_value(Atom.to_string(k), v)}
    end)
  end

  defp normalize_value(k, v)
       when k in ~w(thinking_type reasoning_effort service_tier) and is_binary(v),
       do: String.to_atom(v)

  defp normalize_value(_, v), do: v
end
