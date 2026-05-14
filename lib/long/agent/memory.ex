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
  - **L3 skill index** — Phase 0 `Long.Agent.Skill` rows. Metadata in SQL,
    body on disk under `memory_root`. Registration happens via the
    `mix long.skill` task (or any `Long.Agent.register_skill/1` caller).
  - **L4 session archive** — Phase 0 `Long.Agent.SessionArchive` rows. This
    module provides the synchronous archive function; periodic archival is
    Phase 5's Oban worker.
  """

  alias Long.Agent
  alias Long.Agent.Skill

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
        l1_section(session_id),
        skills_hint(opts)
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

  defp skills_hint(opts) do
    case Keyword.get(opts, :top_skills) do
      nil ->
        nil

      n when is_integer(n) and n > 0 ->
        top = top_skills(n)
        if top == [], do: nil, else: format_top_skills(top)
    end
  end

  defp top_skills(n) do
    case Agent.list_skills() do
      {:ok, skills} ->
        skills
        |> Enum.sort_by(&{-(&1.use_count || 0), &1.last_used_at}, :asc)
        |> Enum.take(n)

      _ ->
        []
    end
  end

  defp format_top_skills(skills) do
    body =
      Enum.map_join(skills, "\n", fn s ->
        "- `#{s.name}` (#{s.kind}, used #{s.use_count}×) — #{s.description || ""}"
      end)

    "## [Skill index — L3 · top]\n" <> body
  end

  @doc """
  Local skill search. Replaces the Python `skill_search/engine.py` HTTP
  client to `fudankw.cn`; we own the rows, so we rank in-process.

  Scores each skill by:

  - `name` match (case-insensitive substring) — weight 3.0
  - `description` match — weight 1.0
  - `tags` exact match — weight 2.0 per matching tag
  - Light boost from recency (`last_used_at`) and `use_count`

  Returns `[%{skill: %Skill{}, score: float, reasons: [String.t()]}]`,
  sorted descending by score, top-`limit`.
  """
  def search_skills(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 10)
    kind = Keyword.get(opts, :kind)
    needles = normalize_query(query)

    case Agent.list_skills() do
      {:ok, skills} ->
        skills
        |> filter_by_kind(kind)
        |> Enum.map(&score_skill(&1, needles))
        |> Enum.reject(&(&1.score <= 0))
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(limit)

      _ ->
        []
    end
  end

  defp normalize_query(query) do
    query
    |> String.downcase()
    |> String.split(~r/[\s,;]+/, trim: true)
    |> Enum.reject(&(&1 == ""))
  end

  defp filter_by_kind(skills, nil), do: skills
  defp filter_by_kind(skills, kind), do: Enum.filter(skills, &(&1.kind == kind))

  defp score_skill(%Skill{} = s, needles) do
    name_lower = String.downcase(s.name || "")
    desc_lower = String.downcase(s.description || "")
    tags_lower = MapSet.new(Enum.map(s.tags || [], &String.downcase/1))

    {score, reasons} =
      Enum.reduce(needles, {0.0, []}, fn n, {acc, reasons} ->
        cond do
          String.contains?(name_lower, n) -> {acc + 3.0, reasons ++ ["name~#{n}"]}
          MapSet.member?(tags_lower, n) -> {acc + 2.0, reasons ++ ["tag=#{n}"]}
          String.contains?(desc_lower, n) -> {acc + 1.0, reasons ++ ["desc~#{n}"]}
          true -> {acc, reasons}
        end
      end)

    boost = use_count_boost(s.use_count) + recency_boost(s.last_used_at)
    %{skill: s, score: score + boost, reasons: reasons}
  end

  defp use_count_boost(nil), do: 0.0
  defp use_count_boost(0), do: 0.0
  defp use_count_boost(n) when is_integer(n), do: :math.log(n + 1) * 0.1

  defp recency_boost(nil), do: 0.0

  defp recency_boost(%DateTime{} = ts) do
    days_ago = DateTime.diff(DateTime.utc_now(), ts, :second) / 86_400.0
    if days_ago < 0, do: 0.0, else: max(0.0, 0.5 * :math.exp(-days_ago / 30.0))
  end

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
         {:ok, %{title: title, summary: summary, insights: insights}} <- summarizer.(messages),
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
