defmodule Long.Jido.Tools.WebScan do
  @moduledoc """
  Fetch and simplify any URL via the Obscura CLI (`obscura fetch URL --dump html`).
  Replaces the older CDP-WebSocket-driven scan: every call gets its own
  fresh browser, with anti-detect stealth on by default. No persistent
  "current page" concept — pass a URL on every call.

  Per-run dedup + circuit breaker (via the `:scan_cache` ETS table that
  `Long.Jido.Loop` creates and threads through `tool_ctx`):

    - A URL that already returned successfully in this run is replayed
      from cache instead of spawning Obscura again.
    - A URL that has failed twice short-circuits on the third attempt
      with a synthetic "URL keeps failing" result so the LLM stops
      grinding the same dead link.
  """

  use Jido.Action,
    name: "web_scan",
    description:
      "Open a URL in a real headless browser (Obscura), wait for JS to render, " <>
        "then return the simplified page text + clickable elements. " <>
        "**This is the default tool for visiting any user-facing webpage** — " <>
        "news articles, blog posts, search-result links, dashboards, SPAs. " <>
        "After `web_search` returns URLs, use this (not `http_fetch`) to read " <>
        "their content.",
    category: "web",
    tags: ["browser", "render"],
    vsn: "2.0.0",
    schema:
      Zoi.object(%{
        url: Zoi.string(description: "Absolute URL to fetch"),
        text_only: Zoi.boolean() |> Zoi.optional() |> Zoi.default(false),
        wait_until:
          Zoi.string(
            description: "Page-readiness signal: load (default) | domcontentloaded | networkidle0"
          )
          |> Zoi.optional(),
        timeout_s:
          Zoi.integer(description: "Max navigation time in seconds (default 25)")
          |> Zoi.optional()
      })

  alias Long.Agent.Browser.Cli
  alias Long.Agent.Browser.SimpHtml

  @max_elements 50
  @failure_cutoff 2

  @impl true
  def run(params, ctx) do
    url = params[:url] || params["url"] || ""

    if url == "" do
      {:ok, %{status: "error", msg: "url is required"}}
    else
      cache_lookup(ctx[:scan_cache], url) |> dispatch(url, params, ctx)
    end
  end

  defp dispatch({:hit, cached}, _url, _params, _ctx),
    do: {:ok, Map.put(cached, :cached, true)}

  defp dispatch(:circuit_broken, url, _params, _ctx) do
    {:ok,
     %{
       status: "error",
       url: url,
       msg:
         "This URL has failed #{@failure_cutoff}+ times in this run. " <>
           "Skipping further attempts — try a different URL.",
       circuit_broken: true
     }}
  end

  defp dispatch(:miss, url, params, ctx) do
    result = do_scan(url, params)
    cache_store(ctx[:scan_cache], url, result)
    result
  end

  defp do_scan(url, params) do
    cli_opts = build_cli_opts(params)

    case Cli.dump(url, [{:format, :html} | cli_opts]) do
      {:ok, html} ->
        build_payload(url, html, params)

      {:error, :not_installed} ->
        {:ok,
         %{
           status: "error",
           msg:
             "Obscura headless browser is not installed yet. " <>
               "Background install may still be running — retry shortly. " <>
               "Or run `mix long.obscura.install` to install manually."
         }}

      {:error, reason} ->
        {:ok,
         %{
           status: "error",
           url: url,
           msg: inspect(reason),
           hint: cli_error_hint(reason)
         }}
    end
  end

  defp build_payload(url, html, params) do
    case SimpHtml.simplify(html) do
      {:ok, simplified} ->
        payload = %{
          status: "success",
          url: url,
          title: simplified.title,
          text: simplified.text
        }

        payload =
          if params[:text_only] == true,
            do: payload,
            else: Map.merge(payload, capped_elements(simplified.elements))

        {:ok, payload}

      {:error, reason} ->
        {:ok, %{status: "error", url: url, msg: "simplify failed: #{inspect(reason)}"}}
    end
  end

  defp capped_elements(elements) when is_list(elements) do
    total = length(elements)

    if total > @max_elements do
      %{elements: Enum.take(elements, @max_elements), elements_total: total, elements_truncated: true}
    else
      %{elements: elements, elements_total: total, elements_truncated: false}
    end
  end

  defp build_cli_opts(params) do
    [:wait_until, :timeout_s]
    |> Enum.reduce([], fn key, acc ->
      case params[key] do
        nil -> acc
        v -> [{key, v} | acc]
      end
    end)
  end

  defp cli_error_hint({:cli_exit, _status, _stderr}),
    do: "Page didn't settle within the navigation timeout. Try `wait_until: \"load\"` or `wait_until: \"domcontentloaded\"`, or skip this URL."

  defp cli_error_hint(_), do: nil

  # ── cache helpers ────────────────────────────────────────────────────

  defp cache_lookup(nil, _url), do: :miss

  defp cache_lookup(table, url) do
    case :ets.lookup(table, url) do
      [{^url, {:ok, payload}}] -> {:hit, payload}
      [{^url, {:fail, n}}] when n >= @failure_cutoff -> :circuit_broken
      _ -> :miss
    end
  end

  defp cache_store(nil, _url, _result), do: :ok

  defp cache_store(table, url, {:ok, %{status: "success"} = payload}) do
    :ets.insert(table, {url, {:ok, payload}})
    :ok
  end

  defp cache_store(table, url, _result) do
    count =
      case :ets.lookup(table, url) do
        [{^url, {:fail, n}}] -> n + 1
        _ -> 1
      end

    :ets.insert(table, {url, {:fail, count}})
    :ok
  end
end
