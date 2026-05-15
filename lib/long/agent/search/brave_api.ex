defmodule Long.Agent.Search.BraveApi do
  @moduledoc """
  Brave Search API provider — the official paid API (free tier
  2,000 queries/month).

  **Distinct from `Long.Agent.Search.Brave`**, which scrapes the public
  search.brave.com HTML. This module hits
  `https://api.search.brave.com/res/v1/web/search` with an
  `X-Subscription-Token` header. Same engine, very different
  reliability profile.

  Response shape (we only need the `web.results` array):

      {
        "web": {
          "results": [
            {"title": "…", "url": "…", "description": "…", …},
            …
          ]
        },
        …
      }
  """

  alias Long.Agent.Search.{Result, Text}

  @endpoint "https://api.search.brave.com/res/v1/web/search"

  @spec search(String.t(), keyword()) :: {:ok, [Result.t()]} | {:error, term()}
  def search(query, opts \\ []) when is_binary(query) do
    api_key = Keyword.fetch!(opts, :api_key)
    http = Keyword.get(opts, :http, &Req.request/1)
    limit = Keyword.get(opts, :limit, 10)

    request =
      http.(
        method: :get,
        url: @endpoint,
        params: %{q: query, count: min(limit, 20)},
        headers: [
          {"x-subscription-token", api_key},
          {"accept", "application/json"},
          {"accept-encoding", "gzip"}
        ],
        retry: false,
        receive_timeout: 8_000
      )

    case request do
      {:ok, %Req.Response{status: 200, body: %{"web" => %{"results" => results}}}}
      when is_list(results) ->
        {:ok, parse(results, limit)}

      {:ok, %Req.Response{status: 200, body: _}} ->
        # No web.results section (could be query that only returned news /
        # discussion blocks). Treat as zero hits, not an error.
        {:ok, []}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_status, status, summarize_error(body)}}

      {:error, e} ->
        {:error, e}
    end
  end

  defp parse(results, limit) do
    results
    |> Enum.map(fn r ->
      %Result{
        title: Text.clean(r["title"]),
        url: r["url"] || "",
        snippet: Text.clean_html(r["description"])
      }
    end)
    |> Enum.filter(&(&1.url != ""))
    |> Enum.take(limit)
  end

  defp summarize_error(%{} = body), do: Map.take(body, ["error", "message", "type"])
  defp summarize_error(other), do: other
end
