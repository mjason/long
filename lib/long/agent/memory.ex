defmodule Long.Agent.Memory do
  @moduledoc """
  Phase 3 — L1/L2/L3/L4 memory façade.

  The hybrid storage decision is captured in the project memory file
  (`project_genericagent_migration.md`):

  - **L1 working checkpoint** — Phase 0 `Long.Agent.WorkingCheckpoint` row
    (one per session). Updated via the `update_working_checkpoint` tool.
  - **L2 global memory** — Phase 0 `Long.Agent.GlobalMemory` rows, scoped
    `:general` / `:insight`. Updated at runtime via the `memory_upsert` tool;
    no auto-importer from the Python source.
  - **L3 skill index** — filesystem under `skill_root`, indexed by
    `Long.Agent.Skill.Store` (in-memory ETS). This module no longer
    touches skills.
  - **L4 session archive** — Phase 0 `Long.Agent.SessionArchive` rows. This
    module provides the synchronous archive function; periodic archival is
    Phase 5's Oban worker.
  """

  alias Long.Agent

  @doc """
  Build the system prompt for a new turn, optionally seeded with a static
  `prefix`. Pulls the session's L1 working checkpoint (if any) and the
  scoped L2 global memory.

  When `session_id` is `nil`, only L2 is applied — useful for ephemeral
  loops.
  """
  def build_system_prompt(session_id, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "")

    sections =
      [
        prefix,
        l2_section(),
        l1_section(session_id)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n\n")
  end

  defp l1_section(nil), do: nil

  defp l1_section(session_id) do
    case Agent.get_checkpoint(session_id) do
      {:ok, %{key_info: key_info}} when is_binary(key_info) and key_info != "" ->
        "## [Working memory — L1]\n" <> key_info

      _ ->
        nil
    end
  end

  defp l2_section do
    case Agent.list_global_memory() do
      {:ok, []} ->
        nil

      {:ok, rows} ->
        grouped = Enum.group_by(rows, & &1.scope)

        grouped
        |> Enum.sort_by(fn {scope, _} -> scope_order(scope) end)
        |> Enum.map_join("\n\n", fn {scope, entries} ->
          header = "## [Global memory — L2 · #{scope}]"
          body = Enum.map_join(entries, "\n", &"- **#{&1.key}**: #{&1.value}")
          header <> "\n" <> body
        end)

      _ ->
        nil
    end
  end

  defp scope_order(:insight), do: 0
  defp scope_order(:general), do: 1
  defp scope_order(_), do: 2

  @doc """
  Synchronous L4 archive: serializes a finished session's messages + final
  working checkpoint into a `SessionArchive` row.

  `summary_fn` is called with the message history list and must return
  `{:ok, %{title, summary, insights}}` or `{:error, reason}`. Defaults to a
  trivial heuristic (`default_summarizer/1`) so the function is usable
  without an LLM round-trip — Phase 5 will wire an LLM-driven summarizer.
  """
  def archive_session(session_id, opts \\ []) do
    summarizer = Keyword.get(opts, :summary_fn, &default_summarizer/1)

    with {:ok, session} <- Agent.get_session(session_id),
         {:ok, messages} <- load_messages(session_id),
         # Summarize only human-visible rows — a silent reflection's internal
         # monologue must not bleed into the operator-facing summary/insights
         # at /manage/sessions. The full payload keeps internal rows for replay.
         visible = Enum.reject(messages, & &1.internal),
         {:ok, %{title: title, summary: summary, insights: insights}} <- summarizer.(visible),
         {:ok, checkpoint} <- maybe_load_checkpoint(session_id) do
      payload = %{
        "session" => %{
          "id" => session.id,
          "title" => session.title,
          "llm_alias" => session.llm_alias
        },
        "messages" => Enum.map(messages, &message_to_json/1),
        "checkpoint" => (checkpoint && checkpoint.key_info) || nil
      }

      Agent.archive_payload(%{
        original_session_id: session_id,
        title: title || session.title,
        summary: summary,
        insights: insights,
        payload: payload,
        archived_at: DateTime.utc_now()
      })
    end
  end

  defp load_messages(session_id) do
    case Agent.list_messages() do
      {:ok, all} ->
        {:ok,
         all |> Enum.filter(&(&1.session_id == session_id)) |> Enum.sort_by(& &1.inserted_at, DateTime)}

      err ->
        err
    end
  end

  defp maybe_load_checkpoint(session_id) do
    case Agent.get_checkpoint(session_id) do
      {:ok, cp} -> {:ok, cp}
      _ -> {:ok, nil}
    end
  end

  defp message_to_json(m) do
    %{
      "role" => to_string(m.role),
      "content" => m.content,
      "turn" => m.turn,
      "tool_calls" => m.tool_calls,
      "tool_results" => m.tool_results
    }
  end

  @doc """
  Cheap fallback summarizer: pulls the first user turn as the title, joins
  the assistant texts into a summary, and dumps no insights. Sufficient for
  unit tests and as a deterministic seed before Phase 5 swaps in an LLM
  summarizer.
  """
  def default_summarizer(messages) do
    first_user =
      Enum.find_value(messages, "", fn m ->
        if m.role == :user, do: m.content, else: nil
      end)

    assistant_text =
      messages
      |> Enum.filter(&(&1.role == :assistant))
      |> Enum.map(&(&1.content || ""))
      |> Enum.join("\n\n")
      |> String.slice(0, 4000)

    {:ok, %{title: String.slice(first_user || "", 0, 80), summary: assistant_text, insights: ""}}
  end
end
