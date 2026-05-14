defmodule Long.Agent.Tools.StartLongTermUpdate do
  @moduledoc """
  Phase 3 placeholder for `do_start_long_term_update`. The Python tool
  triggers L4 archival of the current session into `memory/L4_raw_sessions/`
  via an LLM-driven summarizer. We expose the same tool surface so the
  model's behaviour stays unchanged, but the heavy lifting (LLM call +
  scheduled archival) lives in Phase 5's Oban worker.

  For now: synchronously calls `Long.Agent.Memory.archive_session/2` with
  the default summarizer when a `session_id` is present; otherwise returns
  a no-op outcome.
  """

  @behaviour Long.Agent.Tool

  alias Long.Agent.{Memory, StepOutcome, Tool, ToolContext}

  @impl true
  def name, do: "start_long_term_update"

  @impl true
  def schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => name(),
        "description" =>
          "Mark the end of a task and archive it to long-term memory (L4). " <>
            "Use only when you have verified, lasting facts worth preserving.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{},
          "required" => []
        }
      }
    }
  end

  @impl true
  def run(_args, %ToolContext{session_id: nil}) do
    Tool.emit(
      "[Info] No session_id; skipping L4 archive.\n",
      StepOutcome.cont(%{"status" => "skipped", "reason" => "no_session"})
    )
  end

  def run(_args, %ToolContext{session_id: session_id}) do
    outcome =
      case Memory.archive_session(session_id) do
        {:ok, archive} ->
          StepOutcome.cont(%{"status" => "success", "archive_id" => archive.id})

        {:error, e} ->
          StepOutcome.cont(%{"status" => "error", "msg" => inspect(e)})
      end

    Tool.emit("[Info] start_long_term_update → archive\n", outcome)
  end
end
