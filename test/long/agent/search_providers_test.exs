defmodule Long.Agent.SearchProvidersTest do
  use Long.DataCase, async: false

  alias Long.Agent
  alias Long.Agent.Search
  alias Long.Agent.Search.{BraveApi, Result, Tavily}

  describe "Tavily.search/2" do
    test "extracts results from a successful response" do
      stub = fn opts ->
        assert opts[:method] == :post
        assert opts[:url] == "https://api.tavily.com/search"
        body = opts[:json]
        assert body["api_key"] == "tvly-test"
        assert body["query"] == "elixir lang"

        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "query" => "elixir lang",
             "results" => [
               %{
                 "title" => "Elixir",
                 "url" => "https://elixir-lang.org/",
                 "content" => "Dynamic functional language",
                 "score" => 0.94
               },
               %{
                 "title" => "Phoenix",
                 "url" => "https://phoenixframework.org/",
                 "content" => "Web framework"
               }
             ]
           }
         }}
      end

      assert {:ok,
              [
                %Result{url: "https://elixir-lang.org/", title: "Elixir"},
                %Result{url: "https://phoenixframework.org/"}
              ]} = Tavily.search("elixir lang", api_key: "tvly-test", http: stub)
    end

    test "surfaces http errors" do
      stub = fn _opts ->
        {:ok, %Req.Response{status: 401, body: %{"detail" => "invalid api key"}}}
      end

      assert {:error, {:http_status, 401, %{"detail" => "invalid api key"}}} =
               Tavily.search("q", api_key: "bad", http: stub)
    end
  end

  describe "BraveApi.search/2" do
    test "extracts results from web.results" do
      stub = fn opts ->
        assert opts[:method] == :get
        assert opts[:url] == "https://api.search.brave.com/res/v1/web/search"
        assert {"x-subscription-token", "bsv-test"} in opts[:headers]
        params = Keyword.fetch!(opts, :params)
        assert params[:q] == "phoenix"

        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "web" => %{
               "results" => [
                 %{
                   "title" => "Phoenix",
                   "url" => "https://phoenixframework.org/",
                   "description" => "<strong>Phoenix</strong> Framework"
                 }
               ]
             }
           }
         }}
      end

      assert {:ok,
              [
                %Result{
                  url: "https://phoenixframework.org/",
                  title: "Phoenix",
                  snippet: "Phoenix Framework"
                }
              ]} = BraveApi.search("phoenix", api_key: "bsv-test", http: stub)
    end

    test "returns [] when payload has no web.results section" do
      stub = fn _opts ->
        {:ok, %Req.Response{status: 200, body: %{"news" => %{"results" => []}}}}
      end

      assert {:ok, []} = BraveApi.search("q", api_key: "k", http: stub)
    end

    test "surfaces 429 rate-limit errors" do
      stub = fn _opts -> {:ok, %Req.Response{status: 429, body: %{"error" => "rate"}}} end

      assert {:error, {:http_status, 429, %{"error" => "rate"}}} =
               BraveApi.search("q", api_key: "k", http: stub)
    end
  end

  describe "Search.search/2 with configured SearchConfigs" do
    setup do
      {:ok, _} =
        Agent.register_search_config(%{
          alias: "tavily-main",
          provider: :tavily,
          api_key: "tvly-x",
          enabled: true,
          sort_order: 0
        })

      {:ok, _} =
        Agent.register_search_config(%{
          alias: "brave-paid",
          provider: :brave_api,
          api_key: "bsv-y",
          enabled: true,
          sort_order: 1
        })

      :ok
    end

    test "fans out to configured API providers (skipping SERP scrapers)" do
      stub = fn opts ->
        url = Keyword.fetch!(opts, :url)

        cond do
          String.contains?(url, "api.tavily.com") ->
            {:ok,
             %Req.Response{
               status: 200,
               body: %{
                 "results" => [
                   %{"title" => "T1", "url" => "https://same.example/", "content" => "tav"}
                 ]
               }
             }}

          String.contains?(url, "api.search.brave.com") ->
            {:ok,
             %Req.Response{
               status: 200,
               body: %{
                 "web" => %{
                   "results" => [
                     %{"title" => "B1", "url" => "https://same.example/", "description" => "brave"}
                   ]
                 }
               }
             }}

          true ->
            flunk("Unexpected scraper call to #{url}")
        end
      end

      assert {:ok, %{results: [top | _], status: status}} = Search.search("q", http: stub)

      assert top.url == "https://same.example/"
      # Both API providers contributed — merged sources
      assert "tavily-main" in top.sources
      assert "brave-paid" in top.sources

      assert status["tavily-main"] == :ok
      assert status["brave-paid"] == :ok
      refute Map.has_key?(status, :google)
      refute Map.has_key?(status, :duckduckgo)
    end

    test "disabled config is skipped" do
      {:ok, brave_paid} = Agent.get_search_config("brave-paid")
      {:ok, _} = Agent.update_search_config(brave_paid, %{enabled: false})

      stub = fn opts ->
        url = Keyword.fetch!(opts, :url)

        cond do
          String.contains?(url, "api.tavily.com") ->
            {:ok,
             %Req.Response{
               status: 200,
               body: %{"results" => [%{"title" => "T", "url" => "https://t.example/"}]}
             }}

          String.contains?(url, "api.search.brave.com") ->
            flunk("disabled brave-paid should not have been called")

          true ->
            flunk("Unexpected call to #{url}")
        end
      end

      assert {:ok, %{results: [%Result{url: "https://t.example/"}], status: status}} =
               Search.search("q", http: stub)

      assert status["tavily-main"] == :ok
      refute Map.has_key?(status, "brave-paid")
    end

    test "missing api key (no env var either) drops that config" do
      {:ok, brave_paid} = Agent.get_search_config("brave-paid")
      {:ok, _} = Agent.update_search_config(brave_paid, %{api_key: nil, api_key_env_var: "MISSING_VAR"})

      stub = fn opts ->
        url = Keyword.fetch!(opts, :url)

        cond do
          String.contains?(url, "api.tavily.com") ->
            {:ok, %Req.Response{status: 200, body: %{"results" => []}}}

          String.contains?(url, "api.search.brave.com") ->
            flunk("brave-paid without key should not have been called")

          true ->
            flunk("Unexpected call to #{url}")
        end
      end

      assert {:ok, %{status: status}} = Search.search("q", http: stub)
      refute Map.has_key?(status, "brave-paid")
    end
  end

  describe "Search.search/2 falls back to SERP scrapers when no config exists" do
    test "uses the legacy 3-engine SERP path" do
      stub = fn opts ->
        url = Keyword.fetch!(opts, :url)

        cond do
          String.contains?(url, "api.tavily.com") or String.contains?(url, "api.search.brave.com") ->
            flunk("no SearchConfig — should not hit API providers")

          String.contains?(url, "duckduckgo.com") or String.contains?(url, "google.com") or
              String.contains?(url, "brave.com") ->
            {:ok, %Req.Response{status: 200, body: ""}}
        end
      end

      assert {:ok, %{status: status}} = Search.search("q", http: stub)
      assert Map.has_key?(status, :google)
      assert Map.has_key?(status, :duckduckgo)
      assert Map.has_key?(status, :brave)
    end
  end
end
