defmodule Long.Jido.Tools.StartLongTermUpdate do
  @moduledoc """
  Jido.Action port of `Long.Agent.Tools.StartLongTermUpdate`. Triggers
  synchronous L4 archival via `Long.Agent.Memory.archive_session/2` when
  ctx carries a `:session_id`. The full LLM-driven summarizer + scheduled
  archival belongs to Phase 5.
  """

  use Jido.Action,
    name: "start_long_term_update",
    description:
      "Mark the end of a task and archive it to long-term memory (L4). Use only when " <>
        "you have verified, lasting facts worth preserving.",
    category: "memory",
    tags: ["memory", "l4", "archive"],
    vsn: "1.0.0",
    schema: Zoi.object(%{})

  alias Long.Agent.Memory

  @impl true
  def run(_params, ctx) do
    case ctx[:session_id] do
      nil ->
        {:ok, %{status: "skipped", reason: "no_session"}}

      session_id ->
        case Memory.archive_session(session_id) do
          {:ok, archive} -> {:ok, %{status: "success", archive_id: archive.id}}
          {:error, e} -> {:ok, %{status: "error", msg: inspect(e)}}
        end
    end
  end
end
