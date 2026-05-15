defmodule Long.Agent.Search.DuckDuckGo do
  @moduledoc """
  DuckDuckGo SERP with two endpoints:

    * **Primary**: `lite.duckduckgo.com/lite/` — table-based, way less
      anti-bot.
    * **Fallback**: `html.duckduckgo.com/html/` — richer snippets, trips
      a 202 JS-challenge frequently. Retried once with random backoff;
      if still 202, give up.

  Both endpoints wrap outbound URLs in `/l/?uddg=…`; we unwrap.
  """

  alias Long.Agent.Search.{Http, Result, Text}

  @lite_endpoint "https://lite.duckduckgo.com/lite/"
  @html_endpoint "https://html.duckduckgo.com/html/"

  @spec search(String.t(), keyword()) :: {:ok, [Result.t()]} | {:error, term()}
  def search(query, opts \\ []) when is_binary(query) do
    case via_lite(query, opts) do
      {:ok, results} when results != [] -> {:ok, results}
      _ -> via_html_with_retry(query, opts)
    end
  end

  defp via_lite(query, opts) do
    limit = Keyword.get(opts, :limit, 10)
    Http.get_serp(@lite_endpoint, %{q: query}, &(parse_lite(&1) |> Enum.take(limit)), opts)
  end

  defp via_html_with_retry(query, opts) do
    sleeper = Keyword.get(opts, :sleeper, &Process.sleep/1)

    case via_html(query, opts) do
      {:ok, _} = ok ->
        ok

      {:error, {:http_status, 202}} ->
        sleeper.(:rand.uniform(600) + 200)
        via_html(query, opts)

      err ->
        err
    end
  end

  defp via_html(query, opts) do
    limit = Keyword.get(opts, :limit, 10)
    Http.get_serp(@html_endpoint, %{q: query}, &(parse_html(&1) |> Enum.take(limit)), opts)
  end

  @doc false
  def parse_html(html) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, doc} -> doc |> Floki.find(".result") |> Enum.flat_map(&row_html/1)
      {:error, _} -> []
    end
  end

  defp row_html(node) do
    case Floki.find(node, ".result__title a.result__a") do
      [a | _] ->
        title = a |> Floki.text() |> Text.clean()
        href = a |> Floki.attribute("href") |> List.first() || ""

        case decode_redirect(href) do
          "" ->
            []

          url ->
            snippet = node |> Floki.find(".result__snippet") |> Floki.text() |> Text.clean()
            [%Result{title: title, url: url, snippet: snippet}]
        end

      _ ->
        []
    end
  end

  @doc false
  def parse_lite(html) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, doc} -> doc |> Floki.find("a.result-link") |> Enum.flat_map(&row_lite/1)
      {:error, _} -> []
    end
  end

  defp row_lite(anchor) do
    case decode_redirect(anchor |> Floki.attribute("href") |> List.first() || "") do
      "" ->
        []

      url ->
        title = anchor |> Floki.text() |> Text.clean()

        snippet =
          case Floki.find(anchor, "~ td.result-snippet") do
            [td | _] -> td |> Floki.text() |> Text.clean()
            _ -> ""
          end

        [%Result{title: title, url: url, snippet: snippet}]
    end
  end

  defp decode_redirect(""), do: ""

  defp decode_redirect(href) do
    href = if String.starts_with?(href, "//"), do: "https:" <> href, else: href

    case URI.parse(href).query do
      nil ->
        href

      q ->
        case URI.decode_query(q) do
          %{"uddg" => target} when is_binary(target) and target != "" -> target
          _ -> href
        end
    end
  end

  # Back-compat: old tests reference parse/1.
  @doc false
  def parse(html), do: parse_html(html)
end
