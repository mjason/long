defmodule Long.Agent.ToolInventory do
  @moduledoc """
  Renders the "you have these tools right now" preamble that sits at
  the very top of every system prompt.

  Why: even with detailed per-section docs (Web / Skills / GraphQL),
  the model often skips ahead and writes custom scripts before
  noticing a built-in tool covers the case (e.g. proposing `cron`
  while `graphql` with `createScheduledTask` is in the tool list).
  A flat inventory at the top + a "tools first" mandate fixes the
  priority ordering at the prompt level.
  """

  @doc """
  Build the inventory + mandate block. Takes the actual tools list
  for this turn so any future per-session tool filtering shows the
  right names.

  Each tool contributes one bullet:

      - `tool_name` — first sentence of its description

  We grab only the first sentence to keep the inventory dense; the
  full description is still available to the LLM through the
  structured `tools:` parameter that Anthropic / OpenAI ship.
  """
  def render(tools) when is_list(tools) do
    key = {__MODULE__, :rendered, :erlang.phash2(tools)}

    case :persistent_term.get(key, nil) do
      nil ->
        rendered = do_render(tools)
        :persistent_term.put(key, rendered)
        rendered

      cached ->
        cached
    end
  end

  defp do_render(tools) do
    bullets =
      tools
      |> Enum.map(&bullet/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    """
    ## Tool-first mandate (read before doing anything else)

    Before writing custom code, proposing an external mechanism (cron,
    launchd, systemd, manual scripts, system daemons), or telling the
    user to do something themselves, you MUST scan the tool inventory
    below and pick the closest match. Our tools are the first-class
    API — hand-rolling a solution when a tool exists is a bug.

    If unsure whether a tool fits, prefer to **try it** and read the
    error over dismissing it and proposing an alternative.

    ## Available tools — use these

    #{bullets}
    """
  end

  defp bullet(mod) do
    name = safe(mod, :name)
    desc = safe(mod, :description) |> first_sentence()

    case {name, desc} do
      {nil, _} -> nil
      {n, d} when is_binary(n) -> "  - `#{n}` — #{d}"
      _ -> nil
    end
  end

  defp safe(mod, fun) do
    Code.ensure_loaded(mod)
    if function_exported?(mod, fun, 0), do: apply(mod, fun, []), else: nil
  rescue
    _ -> nil
  end

  defp first_sentence(nil), do: ""

  defp first_sentence(desc) when is_binary(desc) do
    desc
    |> String.trim()
    |> String.split(~r/(?<=[.。!?！？])\s+/, parts: 2)
    |> List.first()
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.trim()
  end
end
