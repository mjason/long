defmodule Long.Jido.Tools.MemoryRemember do
  @moduledoc """
  Persist a fact, preference, goal, or decision so it survives the
  agent's local context window. Two scopes:

  - `"session"` — only this conversation. Use for in-flight task
    state, names of files just produced, the user's current focus.
  - `"global"` — every future conversation. Use for stable facts
    about the user (role, time zone, naming conventions, hard rules
    they've stated).

  Same key in the same scope is overwritten (upsert).
  """

  use Jido.Action,
    name: "memory_remember",
    description: """
    Save something to memory. Pick `scope`:

      - "session" — current conversation only (e.g. "today the user is
        working on the auth migration", "we agreed to use Postgres")
      - "global" — survives across all conversations (e.g. "user's
        timezone is UTC+8", "user prefers Elixir over Python")

    Use `kind` to label what this is so future recall can rank it:
    "fact" | "preference" | "goal" | "decision". `importance` 1-5
    biases ranking when many memories match a query.
    """,
    category: "memory",
    tags: ["memory", "remember"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        scope:
          Zoi.string(description: "session | global")
          |> Zoi.optional()
          |> Zoi.default("session"),
        key: Zoi.string(description: "Short identifier; same key overwrites prior value"),
        value: Zoi.string(description: "The actual content in natural language"),
        kind:
          Zoi.string(description: "fact | preference | goal | decision")
          |> Zoi.optional()
          |> Zoi.default("fact"),
        importance:
          Zoi.integer(description: "1 (trivial) … 5 (critical), default 3")
          |> Zoi.optional()
          |> Zoi.default(3)
      })

  alias Long.Agent
  alias Long.Jido.Tools.Format

  @impl true
  def run(params, ctx) do
    key = params[:key] || ""
    value = params[:value] || ""
    kind = parse_kind(params[:kind] || "fact")
    importance = clamp_importance(params[:importance])

    cond do
      key == "" ->
        {:ok, %{status: "error", msg: "key must not be empty"}}

      kind == nil ->
        {:ok, %{status: "error", msg: "invalid kind: #{inspect(params[:kind])}"}}

      true ->
        write(params[:scope] || "session", ctx, key, value, kind, importance)
    end
  end

  defp write("session", ctx, key, value, kind, importance) do
    case Format.require_session_id(ctx) do
      {:ok, sid} ->
        attrs = %{session_id: sid, key: key, value: value, kind: kind, importance: importance}

        case Agent.put_session_memory(attrs) do
          {:ok, row} -> {:ok, %{status: "success", scope: "session", key: row.key}}
          {:error, e} -> {:ok, %{status: "error", msg: Format.ash_error_message(e)}}
        end

      {:error, msg} ->
        {:ok, %{status: "error", msg: msg}}
    end
  end

  defp write("global", _ctx, key, value, kind, importance) do
    attrs = %{
      scope: :general,
      key: key,
      value: value,
      kind: kind,
      importance: importance
    }

    case Agent.put_global_memory(attrs) do
      {:ok, row} -> {:ok, %{status: "success", scope: "global", key: row.key}}
      {:error, e} -> {:ok, %{status: "error", msg: Format.ash_error_message(e)}}
    end
  end

  defp write(other, _, _, _, _, _) do
    {:ok, %{status: "error", msg: "invalid scope: #{inspect(other)}; expected session | global"}}
  end

  defp parse_kind("fact"), do: :fact
  defp parse_kind("preference"), do: :preference
  defp parse_kind("goal"), do: :goal
  defp parse_kind("decision"), do: :decision
  defp parse_kind(_), do: nil

  defp clamp_importance(n) when is_integer(n) and n >= 1 and n <= 5, do: n
  defp clamp_importance(_), do: 3
end
