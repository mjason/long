defmodule Long.Agent.Search do
  @moduledoc """
  Multi-source web search aggregator.

  ## Source resolution

  At search time the aggregator loads `Long.Agent.SearchConfig` rows
  (`enabled: true`) from the DB. If any exist, those are the only
  sources queried — typically Tavily and/or Brave Search API. When the
  table is empty we fall back to the original three SERP scrapers
  (Google CDP / DuckDuckGo / Brave HTML) so dev/test setups without
  API keys still work.

  Results from every source are merged via Reciprocal Rank Fusion
  (`score = Σ 1/(60 + rank)`), deduplicated by normalised URL.

  ## Status reporting

  The returned `:status` map is keyed by source name (e.g.
  `"tavily-main": :ok`, `"google": {:error, …}`) so the caller can
  tell partial blocks from total outages.

  Failures of one source never abort the search; the others' results
  come back regardless.
  """

  alias Long.Agent
  alias Long.Agent.SearchConfig

  alias Long.Agent.Search.{
    Brave,
    BraveApi,
    DuckDuckGo,
    Google,
    Result,
    Tavily
  }

  @default_limit 10
  # Generous enough to cover a Google CDP cold-start: Obscura boot
  # (~2s) + navigate + networkidle0 wait + JS extractor (~8-15s on a
  # heavy SERP). HTTP-only providers (Tavily/Brave API) come back in
  # under 2s and pay no extra cost from this ceiling.
  @default_timeout_ms 25_000
  @rrf_k 60

  # Fallback SERP scrapers — used only when no SearchConfig rows are
  # registered. Order doesn't matter (we fan out in parallel) but the
  # tuple's first element is the status-key the caller sees.
  @scraper_sources [
    {:duckduckgo, {DuckDuckGo, []}},
    {:google, {Google, []}},
    {:brave, {Brave, []}}
  ]

  @type source_key :: atom() | String.t()
  @type status :: %{source_key() => :ok | {:error, term()}}
  @type response :: %{results: [Result.t()], status: status()}

  @spec search(String.t(), keyword()) :: {:ok, response()} | {:error, :empty_query}
  def search(query, opts \\ [])

  def search("", _opts), do: {:error, :empty_query}
  def search(nil, _opts), do: {:error, :empty_query}

  def search(query, opts) when is_binary(query) do
    limit = Keyword.get(opts, :limit, @default_limit)
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    http = Keyword.get(opts, :http, &Req.request/1)
    sources = Keyword.get_lazy(opts, :sources, fn -> resolve_sources(opts) end)

    per_source =
      sources
      |> Task.async_stream(
        fn {name, {mod, mod_opts}} ->
          call_opts = Keyword.merge(mod_opts, http: http, limit: limit)
          {name, mod.search(query, call_opts)}
        end,
        timeout: timeout,
        on_timeout: :kill_task,
        max_concurrency: max(length(sources), 1)
      )
      |> Enum.map(fn
        {:ok, {name, {:ok, list}}} -> {name, {:ok, list}}
        {:ok, {name, {:error, e}}} -> {name, {:error, e}}
        {:exit, reason} -> {:unknown, {:error, {:task_exit, reason}}}
      end)

    results =
      per_source
      |> Enum.flat_map(fn
        {name, {:ok, list}} -> Enum.with_index(list, 1) |> Enum.map(fn {r, i} -> {name, r, i} end)
        _ -> []
      end)
      |> fuse_rrf()
      |> Enum.take(limit)

    status =
      Map.new(per_source, fn
        {name, {:ok, _}} -> {name, :ok}
        {name, {:error, e}} -> {name, {:error, e}}
      end)

    {:ok, %{results: results, status: status}}
  end

  # ── Source resolution ───────────────────────────────────────────────

  # If the operator has registered any `SearchConfig` rows, only those
  # are queried. Otherwise we fall back to the SERP scrapers.
  defp resolve_sources(opts) do
    case load_configured_sources(opts) do
      [] -> @scraper_sources
      list -> list
    end
  end

  defp load_configured_sources(opts) do
    rows =
      case Keyword.fetch(opts, :search_configs) do
        {:ok, list} -> list
        :error -> list_enabled_configs()
      end

    rows
    |> Enum.sort_by(&{&1.sort_order || 0, &1.alias})
    |> Enum.flat_map(&to_source/1)
  end

  defp list_enabled_configs do
    case Agent.list_search_configs() do
      {:ok, rows} -> Enum.filter(rows, & &1.enabled)
      _ -> []
    end
  end

  defp to_source(%SearchConfig{enabled: false}), do: []

  defp to_source(%SearchConfig{provider: provider, alias: a} = cfg) do
    case {provider, resolve_key(cfg)} do
      {:tavily, key} when is_binary(key) and key != "" ->
        [{a, {Tavily, [api_key: key, params: cfg.params]}}]

      {:brave_api, key} when is_binary(key) and key != "" ->
        [{a, {BraveApi, [api_key: key, params: cfg.params]}}]

      _ ->
        []
    end
  end

  defp resolve_key(%SearchConfig{api_key_env_var: var, api_key: key}) do
    cond do
      is_binary(var) and var != "" -> System.get_env(var) || ""
      is_binary(key) and key != "" -> key
      true -> nil
    end
  end

  # ── RRF merge ────────────────────────────────────────────────────────

  # Reciprocal Rank Fusion: for each `(engine, result, rank)` we accumulate
  # `1 / (k + rank)` into the bucket keyed by normalized URL. The bucket
  # also remembers every engine that contributed and uses the first-seen
  # title/snippet (subsequent ones augment if empty).
  defp fuse_rrf(triples) do
    triples
    |> Enum.reduce(%{}, fn {engine, %Result{} = r, rank}, acc ->
      key = normalize_url(r.url)
      contribution = 1.0 / (@rrf_k + rank)

      Map.update(
        acc,
        key,
        merge_seed(r, engine, contribution),
        &merge_bucket(&1, r, engine, contribution)
      )
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.map(&Result.with_sources/1)
  end

  defp merge_seed(%Result{} = r, engine, contribution) do
    %Result{
      title: r.title,
      url: r.url,
      snippet: r.snippet,
      sources: [engine],
      score: contribution
    }
  end

  defp merge_bucket(%Result{} = bucket, %Result{} = r, engine, contribution) do
    %Result{
      bucket
      | snippet: best_text(bucket.snippet, r.snippet),
        title: best_text(bucket.title, r.title),
        sources: [engine | bucket.sources],
        score: bucket.score + contribution
    }
  end

  defp best_text(a, b) do
    cond do
      blank?(a) -> b
      blank?(b) -> a
      String.length(b) > String.length(a) * 2 -> b
      true -> a
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""

  # Normalize for dedup: lowercase scheme+host, strip trailing slashes and
  # common tracking query params. Conservative — keep the path.
  defp normalize_url(nil), do: ""

  defp normalize_url(url) when is_binary(url) do
    uri = URI.parse(url)

    host = (uri.host || "") |> String.downcase() |> String.trim_leading("www.")
    path = (uri.path || "/") |> String.trim_trailing("/")
    path = if path == "", do: "/", else: path

    query =
      case uri.query do
        nil -> nil
        "" -> nil
        q -> q |> URI.decode_query() |> strip_tracking() |> URI.encode_query()
      end

    scheme = (uri.scheme || "https") |> String.downcase()
    base = "#{scheme}://#{host}#{path}"
    if query in [nil, ""], do: base, else: base <> "?" <> query
  end

  @tracking_params ~w(utm_source utm_medium utm_campaign utm_content utm_term
                      gclid fbclid mc_cid mc_eid)
  defp strip_tracking(map) when is_map(map), do: Map.drop(map, @tracking_params)
end
