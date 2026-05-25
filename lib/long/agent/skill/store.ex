defmodule Long.Agent.Skill.Store do
  @moduledoc """
  In-memory authoritative cache of every `SKILL.md` discovered under
  `skill_root`. The filesystem is the **source of truth** — there is no
  database table. The Store keeps an ETS index for fast lookup and
  reloads on:

    * boot (`init/1` does a full scan)
    * `file_system` events under `skill_root` (debounced)
    * a 60 s heartbeat tick (rescans whenever the watcher is dead — the
      WSL / NFS fallback path)
    * an explicit `reindex/0` call (the `skill_reindex` LLM tool, or
      `mix long.skill reindex`)

  Per-skill usage stats (`use_count`, `last_used_at`) are persisted to
  `<skill_dir>/.usage.json`, written serially from this GenServer so
  there are no concurrent-writer races. Events on `.usage.json` are
  filtered out of the watcher path to avoid a touch → write → event →
  reindex → touch loop.

  ## ETS table

  Name: `:long_skills` (public, named). Records are `{name, skill_map}`
  for skill rows. A single `{:__names_block__, string}` row caches the
  formatted system-prompt addendum.
  """

  use GenServer

  require Logger

  alias Long.Util.Search

  @table :long_skills
  @skill_filename "SKILL.md"
  @usage_filename ".usage.json"
  @names_block_key :__names_block__
  @debounce_ms 250
  @tick_ms 60_000

  # ── client API ───────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return every skill, sorted by name."
  @spec list_all() :: [map()]
  def list_all do
    :ets.tab2list(@table)
    |> Enum.flat_map(fn
      {@names_block_key, _} -> []
      {_name, skill} -> [skill]
    end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "System-prompt addendum block listing every skill name."
  @spec list_names_for_prompt() :: String.t()
  def list_names_for_prompt do
    case :ets.lookup(@table, @names_block_key) do
      [{@names_block_key, str}] -> str
      [] -> ""
    end
  end

  @doc "Look up one skill by exact name."
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, skill}] -> {:ok, skill}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Keyword-scored search over the ETS index. Returns `[%{row, score}]`.
  """
  @spec search(String.t(), keyword()) :: [%{row: map(), score: float()}]
  def search(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 5)
    needles = Search.normalize(query)

    case needles do
      [] ->
        []

      _ ->
        list_all()
        |> Enum.map(fn r -> %{row: r, score: score_row(r, needles)} end)
        |> Enum.reject(&(&1.score <= 0))
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(limit)
    end
  end

  @doc "Bump `use_count` + `last_used_at` for `name`. Persists to .usage.json."
  @spec touch(String.t()) :: :ok | {:error, :not_found}
  def touch(name) when is_binary(name), do: GenServer.call(__MODULE__, {:touch, name})

  @doc "Force a full rescan of `skill_root`."
  @spec reindex() :: :ok
  def reindex, do: GenServer.call(__MODULE__, :reindex)

  @doc "Return the configured absolute skill_root."
  @spec root() :: Path.t()
  def root do
    case Application.get_env(:long, Long.Agent, [])[:skill_root] do
      nil -> Path.expand("priv/agent/skills", File.cwd!())
      p -> Path.expand(p)
    end
  end

  # ── GenServer ────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{watcher_pid: nil, debounce_ref: nil, last_scan: 0}, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    state = reload(state)
    :timer.send_interval(@tick_ms, :tick)
    {:noreply, state}
  end

  @impl true
  def handle_call(:reindex, _from, state), do: {:reply, :ok, reload(state)}

  def handle_call({:touch, name}, _from, state) do
    case :ets.lookup(@table, name) do
      [{^name, skill}] ->
        updated = %{
          skill
          | use_count: (skill.use_count || 0) + 1,
            last_used_at: DateTime.utc_now()
        }

        :ets.insert(@table, {name, updated})
        write_usage(updated)
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher, :stop}, state) do
    Logger.warning("Skill.Store: file_system watcher stopped — restarting")
    {:noreply, ensure_watcher(%{state | watcher_pid: nil})}
  end

  def handle_info({:file_event, _watcher, {path, _events}}, state) do
    # Filter out our own .usage.json writes — otherwise `skill_read →
    # touch → write_usage` triggers a reindex that re-reads .usage.json
    # and clobbers in-memory counters.
    if Path.basename(path) == @usage_filename do
      {:noreply, state}
    else
      if state.debounce_ref, do: Process.cancel_timer(state.debounce_ref)
      ref = Process.send_after(self(), :debounced_reindex, @debounce_ms)
      {:noreply, %{state | debounce_ref: ref}}
    end
  end

  def handle_info(:debounced_reindex, state) do
    {:noreply, %{reload(state) | debounce_ref: nil}}
  end

  def handle_info(:tick, state) do
    # If the watcher is dead (NFS, watcher crash) we have no event
    # stream, so unconditionally rescan. If it's alive, the cheap root-
    # mtime check catches root-level adds/removes; per-skill body edits
    # come in through events.
    if is_nil(state.watcher_pid) or changed_since_last_scan?(state.last_scan) do
      {:noreply, reload(state)}
    else
      {:noreply, ensure_watcher(state)}
    end
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    if pid == state.watcher_pid do
      {:noreply, %{state | watcher_pid: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── scanning ─────────────────────────────────────────────────────────

  defp reload(state) do
    root = ensure_root()
    do_reindex(root)
    refresh_names_block()
    %{ensure_watcher(state, root) | last_scan: System.system_time(:second)}
  end

  defp do_reindex(root) do
    skill_mds = Path.wildcard(Path.join(root, "**/" <> @skill_filename))

    live_names =
      Enum.reduce(skill_mds, MapSet.new(), fn path, acc ->
        case load_skill(path, root) do
          {:ok, skill} ->
            :ets.insert(@table, {skill.name, skill})
            MapSet.put(acc, skill.name)

          {:error, reason} ->
            Logger.warning("Skill.Store: skipping #{path}: #{reason}")
            acc
        end
      end)

    Enum.each(:ets.tab2list(@table), fn
      {@names_block_key, _} -> :ok
      {name, _} -> unless MapSet.member?(live_names, name), do: :ets.delete(@table, name)
    end)
  end

  defp refresh_names_block do
    block =
      case list_all() do
        [] ->
          ""

        skills ->
          body = Enum.map_join(skills, "\n", &"- `#{&1.name}`")

          """
          # Available skills

          Call `skill_search(query: …)` for descriptions, then `skill_read(name: …)`
          for the full SKILL.md instructions.

          #{body}
          """
      end

    :ets.insert(@table, {@names_block_key, block})
  end

  defp load_skill(skill_md_path, root) do
    skill_dir = Path.dirname(skill_md_path)

    with {:ok, raw} <- File.read(skill_md_path),
         {:ok, frontmatter, body} <- split_frontmatter(raw),
         :ok <- validate_required(frontmatter),
         {:ok, stat} <- File.stat(skill_md_path) do
      usage = read_usage(skill_dir)

      {:ok,
       %{
         name: frontmatter["name"],
         relative_path: Path.relative_to(skill_dir, root),
         absolute_path: skill_dir,
         description: frontmatter["description"],
         tags: list_field(frontmatter, "tags"),
         frontmatter: frontmatter,
         body: String.trim_leading(body),
         use_count: usage[:use_count] || 0,
         last_used_at: usage[:last_used_at],
         mtime: stat.mtime
       }}
    end
  end

  @frontmatter_re ~r/\A---\s*\r?\n(?<yaml>.*?)\r?\n---\s*\r?\n(?<body>.*)\z/s

  defp split_frontmatter(raw) do
    case Regex.named_captures(@frontmatter_re, raw) do
      %{"yaml" => yaml, "body" => body} ->
        case YamlElixir.read_from_string(yaml) do
          {:ok, map} when is_map(map) -> {:ok, map, body}
          {:ok, _} -> {:error, "frontmatter must be a YAML mapping"}
          {:error, reason} -> {:error, "invalid YAML: #{inspect(reason)}"}
        end

      _ ->
        {:error, "missing `---` frontmatter"}
    end
  end

  defp validate_required(%{"name" => n, "description" => d})
       when is_binary(n) and n != "" and is_binary(d) and d != "",
       do: :ok

  defp validate_required(%{"name" => n}) when not is_binary(n) or n == "",
    do: {:error, "frontmatter is missing `name`"}

  defp validate_required(_), do: {:error, "frontmatter is missing `description`"}

  defp list_field(fm, key) do
    case Map.get(fm, key) do
      v when is_list(v) -> Enum.map(v, &to_string/1)
      v when is_binary(v) -> String.split(v, ~r/[,\s]+/, trim: true)
      _ -> []
    end
  end

  # ── usage stats ──────────────────────────────────────────────────────

  defp read_usage(skill_dir) do
    with {:ok, json} <- File.read(Path.join(skill_dir, @usage_filename)),
         {:ok, %{"use_count" => uc} = map} <- Jason.decode(json) do
      %{use_count: uc, last_used_at: parse_iso(map["last_used_at"])}
    else
      _ -> %{}
    end
  end

  defp write_usage(skill) do
    payload = %{
      "use_count" => skill.use_count,
      "last_used_at" => skill.last_used_at && DateTime.to_iso8601(skill.last_used_at)
    }

    File.write(Path.join(skill.absolute_path, @usage_filename), Jason.encode!(payload))
  end

  defp parse_iso(nil), do: nil

  defp parse_iso(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  # ── watcher ──────────────────────────────────────────────────────────

  defp ensure_watcher(state, root \\ nil) do
    root = root || ensure_root()
    alive? = is_pid(state.watcher_pid) and Process.alive?(state.watcher_pid)

    cond do
      alive? -> state
      not File.dir?(root) -> state
      true -> start_fresh_watcher(state, root)
    end
  end

  defp start_fresh_watcher(state, root) do
    # `:ignore` is returned when file_system can't find a native backend
    # (e.g. a Debian box without `inotify-tools`); treat it like an error
    # and fall back to the mtime poll instead of crashing the Store —
    # which previously took the whole app down at boot.
    case FileSystem.start_link(dirs: [root], name: nil) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        %{state | watcher_pid: pid}

      other ->
        Logger.warning(
          "Skill.Store: file_system watcher unavailable (#{inspect(other)}); " <>
            "falling back to 60s mtime poll"
        )

        %{state | watcher_pid: nil}
    end
  end

  defp ensure_root do
    root = root()
    File.mkdir_p!(root)
    root
  end

  defp changed_since_last_scan?(last) do
    # `time: :posix` avoids the local-time gotcha — File.stat defaults
    # to local-time tuples, which break on non-UTC servers.
    case File.stat(root(), time: :posix) do
      {:ok, %{mtime: m}} -> m > last
      _ -> false
    end
  end

  # ── ranking ──────────────────────────────────────────────────────────

  defp score_row(row, needles) do
    name = String.downcase(row.name || "")
    desc = String.downcase(row.description || "")
    tag_blob = row.tags |> Enum.map(&String.downcase/1) |> Enum.join(" ")
    body = String.downcase(row.body || "")

    keyword_score =
      Enum.reduce(needles, 0.0, fn n, acc ->
        cond do
          String.contains?(name, n) -> acc + 3.0
          String.contains?(tag_blob, n) -> acc + 2.0
          String.contains?(desc, n) -> acc + 1.5
          String.contains?(body, n) -> acc + 0.5
          true -> acc
        end
      end)

    keyword_score + use_count_boost(row.use_count) + Search.recency_boost(row.last_used_at)
  end

  defp use_count_boost(nil), do: 0.0
  defp use_count_boost(n) when is_integer(n) and n > 0, do: :math.log(n + 1) * 0.3
  defp use_count_boost(_), do: 0.0
end
