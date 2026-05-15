defmodule Long.Jido.Tools.WebSearch do
  @moduledoc """
  Multi-engine web search tool. Fans out the query to Google,
  DuckDuckGo, and Brave in parallel, then merges the results with
  Reciprocal Rank Fusion — see `Long.Agent.Search`.

  Returns the top-N hits each as `%{title, url, snippet, sources}`,
  plus a per-engine status map so the agent can tell partial blocks
  from clean responses.

  When all three engines fail (CAPTCHA, network), the tool returns
  `%{status: "error", …}` but never crashes the loop.
  """

  use Jido.Action,
    name: "web_search",
    description:
      "Search the web. Uses configured search APIs (Tavily / Brave Search API) " <>
        "if available; otherwise falls back to aggregating Google + DuckDuckGo " <>
        "+ Brave SERPs (RRF-merged). Returns a list of `{title, url, snippet, sources}`. " <>
        "**Follow-up**: to read the actual content of a result URL, call " <>
        "`web_scan` with that URL — almost every modern site (news, blogs, " <>
        "social, knowledge bases) needs a real browser to render. Use " <>
        "`http_fetch` only when the target is a machine endpoint (API/JSON/RSS).",
    category: "web",
    tags: ["search", "api"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        query: Zoi.string(description: "Search query (natural language or keywords)"),
        limit:
          Zoi.integer(description: "Maximum hits to return (default 10)")
          |> Zoi.optional()
          |> Zoi.default(10)
      })

  alias Long.Agent.Search

  @impl true
  def run(params, _ctx) do
    query = (params[:query] || params["query"] || "") |> to_string() |> String.trim()
    limit = params[:limit] || params["limit"] || 10

    case Search.search(query, limit: limit) do
      {:ok, %{results: [], status: status}} ->
        {:ok,
         %{
           status: "empty",
           query: query,
           engines: stringify_status(status),
           results: [],
           hint:
             "All search engines returned zero results or were blocked. " <>
               "Try a different query, or fall back to `http_fetch`/`web_scan` " <>
               "on a known URL."
         }}

      {:ok, %{results: rs, status: status}} ->
        {:ok,
         %{
           status: "success",
           query: query,
           engines: stringify_status(status),
           results: Enum.map(rs, &to_payload/1)
         }}

      {:error, :empty_query} ->
        {:ok, %{status: "error", msg: "query must not be empty"}}
    end
  end

  defp to_payload(%Long.Agent.Search.Result{} = r) do
    %{
      title: r.title,
      url: r.url,
      snippet: r.snippet,
      sources: Enum.map(r.sources, &to_key/1)
    }
  end

  defp stringify_status(status) do
    Map.new(status, fn
      {engine, :ok} -> {to_key(engine), "ok"}
      {engine, {:error, e}} -> {to_key(engine), "error: " <> inspect(e)}
    end)
  end

  # Source keys are atoms for SERP scrapers (`:google`, `:duckduckgo`, …)
  # and strings for SearchConfig rows (their `alias`, e.g. `"默认搜索"`).
  # Handle both — calling `Atom.to_string/1` on a binary raises ArgumentError.
  defp to_key(k) when is_atom(k), do: Atom.to_string(k)
  defp to_key(k) when is_binary(k), do: k
  defp to_key(k), do: to_string(k)
end
