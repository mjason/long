defmodule Long.Agent.Search.Tavily do
  @moduledoc """
  Tavily Search API provider.

  Endpoint: `POST https://api.tavily.com/search`. API key goes in the
  JSON body (Tavily's convention), not a header.

  Response shape:

      {
        "query": "…",
        "results": [
          {"title": "…", "url": "…", "content": "…", "score": 0.93},
          …
        ],
        "answer": "optional summary",
        …
      }

  The aggregator (`Long.Agent.Search`) feeds `content` into `Result.snippet`.
  """

  alias Long.Agent.Search.{Result, Text}

  @endpoint "https://api.tavily.com/search"
  @default_search_depth "basic"

  @spec search(String.t(), keyword()) :: {:ok, [Result.t()]} | {:error, term()}
  def search(query, opts \\ []) when is_binary(query) do
    api_key = Keyword.fetch!(opts, :api_key)
    http = Keyword.get(opts, :http, &Req.request/1)
    limit = Keyword.get(opts, :limit, 10)
    depth = Keyword.get(opts, :search_depth, @default_search_depth)

    body = %{
      "api_key" => api_key,
      "query" => query,
      "search_depth" => depth,
      "max_results" => limit,
      "include_answer" => false,
      "include_images" => false
    }

    request =
      http.(
        method: :post,
        url: @endpoint,
        json: body,
        headers: [{"content-type", "application/json"}],
        retry: false,
        receive_timeout: 12_000
      )

    case request do
      {:ok, %Req.Response{status: 200, body: %{"results" => results}}} when is_list(results) ->
        {:ok, parse(results, limit)}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:error, {:unexpected_payload, body}}

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
        snippet: Text.clean(r["content"])
      }
    end)
    |> Enum.filter(&(&1.url != ""))
    |> Enum.take(limit)
  end

  defp summarize_error(%{} = body), do: Map.take(body, ["detail", "error", "message"])
  defp summarize_error(other), do: other
end
