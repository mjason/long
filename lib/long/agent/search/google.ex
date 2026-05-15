defmodule Long.Agent.Search.Google do
  @moduledoc """
  Google SERP search.

  Google aggressively blocks raw HTTP scraping (consent walls, sorry
  pages, JS-only rendering). The default transport is `:cdp` — we drive
  the configured headless engine (`Long.Agent.Browser.Engine` →
  Obscura/Chrome) to navigate to `google.com/search?q=…` and evaluate
  a JS extractor against the rendered DOM. The extractor is defensive
  about Google's class-name churn: it walks every `<a>` that has an
  `<h3>` descendant, decodes the `/url?q=` redirect if present, and
  pulls the nearest snippet-ish text.

  If CDP isn't reachable (no engine installed, `:external` mode with
  nothing running) or returns no results, we fall back to plain HTTP —
  which usually loses to Google but is better than nothing for unit
  tests and local dev without a browser.

  ## Transport selection

  - `transport: :auto` (default) — try CDP first, fall back to HTTP.
  - `transport: :cdp` — CDP only; `{:ok, []}` on miss instead of falling
    back.
  - `transport: :http` — HTTP only. Tests pass `http: stub` which also
    forces this path.
  """

  alias Long.Agent.Search.{Cdp, Http, Result, Text}

  @endpoint "https://www.google.com/search"

  @serp_extractor_js """
  (() => {
    const out = [];
    const seen = new Set();
    const anchors = document.querySelectorAll('a');
    for (const a of anchors) {
      const h3 = a.querySelector('h3');
      if (!h3) continue;
      let href = a.href || '';
      if (href.startsWith('/url?')) {
        try {
          const p = new URLSearchParams(href.slice(5));
          href = p.get('q') || href;
        } catch (e) {}
      }
      if (!href.startsWith('http')) continue;
      try {
        const host = new URL(href).hostname;
        if (host.endsWith('google.com')) continue;
      } catch (e) { continue; }
      if (seen.has(href)) continue;
      seen.add(href);

      // Walk up a few ancestors hunting for a text-y sibling that
      // doesn't repeat the title.
      let snippet = '';
      let node = a.parentElement;
      let hops = 0;
      while (node && hops < 4) {
        const c = node.querySelector('[data-sncf], .VwiC3b, .yXK7lf, .lEBKkf, span.aCOpRe');
        if (c && c.innerText && !c.contains(h3)) { snippet = c.innerText; break; }
        node = node.parentElement;
        hops++;
      }

      out.push({ title: h3.innerText || '', url: href, snippet });
      if (out.length >= 20) break;
    }
    return JSON.stringify(out);
  })()
  """

  @spec search(String.t(), keyword()) :: {:ok, [Result.t()]} | {:error, term()}
  def search(query, opts \\ []) when is_binary(query) do
    transport = resolve_transport(opts)

    case transport do
      :http -> search_via_http(query, opts)
      :cdp -> search_via_cdp(query, opts)
      :auto -> try_cdp_then_http(query, opts)
    end
  end

  # Tests pass `http: stub` to force the HTTP code path. Without that,
  # default to `:auto` (CDP first, HTTP fallback).
  defp resolve_transport(opts) do
    cond do
      Keyword.has_key?(opts, :transport) -> Keyword.fetch!(opts, :transport)
      Keyword.has_key?(opts, :http) -> :http
      true -> :auto
    end
  end

  defp try_cdp_then_http(query, opts) do
    case search_via_cdp(query, opts) do
      {:ok, []} -> search_via_http(query, opts)
      {:ok, _} = ok -> ok
      {:error, _} -> search_via_http(query, opts)
    end
  end

  # ── CDP transport ────────────────────────────────────────────────────

  defp search_via_cdp(query, opts) do
    limit = Keyword.get(opts, :limit, 10)
    cdp = Keyword.get(opts, :cdp_mod, Cdp)
    url = "#{@endpoint}?q=#{URI.encode_www_form(query)}&hl=en&num=#{max(limit, 10)}"

    with {:ok, json} when is_binary(json) <- cdp.render_and_eval(url, @serp_extractor_js, opts),
         {:ok, list} when is_list(list) <- Jason.decode(json) do
      results =
        list
        |> Enum.map(fn r ->
          %Result{
            title: Text.clean(r["title"]),
            url: r["url"] || "",
            snippet: Text.clean(r["snippet"])
          }
        end)
        |> Enum.filter(&(&1.url != ""))
        |> Enum.take(limit)

      {:ok, results}
    else
      {:ok, _other} -> {:error, :unexpected_cdp_payload}
      {:error, _} = e -> e
      err -> {:error, err}
    end
  end

  # ── HTTP transport (fallback / test path) ────────────────────────────

  defp search_via_http(query, opts) do
    limit = Keyword.get(opts, :limit, 10)
    params = %{q: query, hl: "en", num: max(limit, 10)}
    Http.get_serp(@endpoint, params, &(parse(&1) |> Enum.take(limit)), opts)
  end

  @doc false
  def parse(html) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, doc} -> extract(doc)
      {:error, _} -> []
    end
  end

  defp extract(doc) do
    doc
    |> Floki.find("a:has(h3)")
    |> Enum.flat_map(&row/1)
    |> Enum.uniq_by(& &1.url)
  end

  defp row(anchor) do
    href = anchor |> Floki.attribute("href") |> List.first() || ""

    with target when target != "" <- decode_redirect(href),
         true <- result_link?(target) do
      title = anchor |> Floki.find("h3") |> Floki.text() |> Text.clean()
      snippet = nearest_snippet(anchor)
      [%Result{title: title, url: target, snippet: snippet}]
    else
      _ -> []
    end
  end

  defp decode_redirect("/url?" <> rest), do: rest |> URI.decode_query() |> Map.get("q", "")
  defp decode_redirect("http" <> _ = href), do: href
  defp decode_redirect(_), do: ""

  defp result_link?(url) do
    host = URI.parse(url).host || ""
    host != "" and host != "www.google.com" and host != "google.com"
  end

  defp nearest_snippet(anchor) do
    case Floki.find(anchor, "+ div") do
      [] -> ""
      [div | _] -> div |> Floki.text() |> Text.clean()
    end
  end
end
