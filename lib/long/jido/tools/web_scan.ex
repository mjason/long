defmodule Long.Jido.Tools.WebScan do
  @moduledoc """
  Fetch and simplify any URL via the Obscura CLI (`obscura fetch URL --dump html`).
  Replaces the older CDP-WebSocket-driven scan: every call gets its own
  fresh browser, with anti-detect stealth on by default. No persistent
  "current page" concept — pass a URL on every call.
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

  @impl true
  def run(params, _ctx) do
    url = params[:url] || params["url"] || ""

    if url == "" do
      {:ok, %{status: "error", msg: "url is required"}}
    else
      do_scan(url, params)
    end
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
        {:ok, %{status: "error", msg: inspect(reason)}}
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

  # Cap the elements list so a page with hundreds of links doesn't blow
  # up the LLM context. `elements_truncated`/`elements_total` let the
  # model decide whether to fetch a deeper view (e.g. via web_execute_js
  # with a tighter selector).
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
end
