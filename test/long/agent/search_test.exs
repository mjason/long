defmodule Long.Agent.SearchTest do
  use ExUnit.Case, async: true

  alias Long.Agent.Search
  alias Long.Agent.Search.{Brave, DuckDuckGo, Google, Result}

  describe "DuckDuckGo.parse/1" do
    test "extracts title/url/snippet and decodes the `uddg` redirect" do
      html = """
      <div class="results">
        <div class="result results_links">
          <h2 class="result__title">
            <a class="result__a"
               href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fphoenixframework.org%2F&rut=abc">
              Phoenix Framework
            </a>
          </h2>
          <a class="result__snippet">A productive web framework</a>
        </div>
        <div class="result results_links">
          <h2 class="result__title">
            <a class="result__a"
               href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fhexdocs.pm%2Fphoenix">
              Phoenix on Hexdocs
            </a>
          </h2>
          <a class="result__snippet">API docs</a>
        </div>
      </div>
      """

      assert [
               %Result{
                 title: "Phoenix Framework",
                 url: "https://phoenixframework.org/",
                 snippet: "A productive web framework"
               },
               %Result{
                 title: "Phoenix on Hexdocs",
                 url: "https://hexdocs.pm/phoenix",
                 snippet: "API docs"
               }
             ] = DuckDuckGo.parse(html)
    end

    test "returns [] on malformed/empty HTML" do
      assert DuckDuckGo.parse("") == []
      assert DuckDuckGo.parse("<html><body>no results</body></html>") == []
    end
  end

  describe "Google.parse/1" do
    test "extracts anchor-with-h3, decodes /url?q= redirects, filters internal links" do
      html = """
      <html><body>
        <div>
          <a href="/url?q=https://example.com/article&sa=U&ved=1">
            <h3>Example article</h3>
          </a>
          <div>An interesting article</div>
        </div>
        <div>
          <a href="https://hexdocs.pm/elixir"><h3>Elixir docs</h3></a>
        </div>
        <a href="https://www.google.com/preferences"><h3>Settings</h3></a>
      </body></html>
      """

      results = Google.parse(html)
      urls = Enum.map(results, & &1.url)

      assert "https://example.com/article" in urls
      assert "https://hexdocs.pm/elixir" in urls
      refute Enum.any?(urls, &String.contains?(&1, "google.com"))
    end

    test "returns [] when no anchor has an h3 (CAPTCHA / consent page)" do
      assert Google.parse("<html><body>Before you continue...</body></html>") == []
    end
  end

  describe "DuckDuckGo.parse_lite/1" do
    test "extracts results from the lite table layout" do
      html = """
      <html><body><table>
        <tr><td>1.</td>
          <td><a class="result-link"
                 href="//duckduckgo.com/l/?uddg=https%3A%2F%2Felixir-lang.org%2F&rut=x">
                Elixir language
              </a>
          </td>
        </tr>
        <tr><td></td>
          <td class="result-snippet">A dynamic functional language</td>
        </tr>
        <tr><td>2.</td>
          <td><a class="result-link"
                 href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fhexdocs.pm%2Felixir">
                Elixir docs
              </a>
          </td>
        </tr>
      </table></body></html>
      """

      assert [
               %Result{title: "Elixir language", url: "https://elixir-lang.org/"},
               %Result{title: "Elixir docs", url: "https://hexdocs.pm/elixir"}
             ] = DuckDuckGo.parse_lite(html)
    end
  end

  describe "DuckDuckGo.search/2 — lite primary + html fallback" do
    test "uses lite endpoint successfully when results are present" do
      stub = fn opts ->
        url = Keyword.fetch!(opts, :url)

        cond do
          String.contains?(url, "lite.duckduckgo.com") ->
            {:ok,
             %Req.Response{
               status: 200,
               body: """
               <html><body><table>
                 <tr><td>1.</td><td><a class="result-link"
                       href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fa.example%2F">A</a></td></tr>
               </table></body></html>
               """
             }}

          true ->
            flunk("should not hit html endpoint when lite succeeds — got #{url}")
        end
      end

      assert {:ok, [%Result{url: "https://a.example/"}]} =
               Long.Agent.Search.DuckDuckGo.search("q", http: stub)
    end

    test "falls back to html endpoint when lite returns 0 results" do
      stub = fn opts ->
        url = Keyword.fetch!(opts, :url)

        cond do
          String.contains?(url, "lite.duckduckgo.com") ->
            {:ok, %Req.Response{status: 200, body: "<html><body>no table here</body></html>"}}

          String.contains?(url, "html.duckduckgo.com") ->
            {:ok,
             %Req.Response{
               status: 200,
               body: """
               <html><body><div class="results">
                 <div class="result results_links">
                   <h2 class="result__title">
                     <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fb.example%2F">B</a>
                   </h2>
                   <a class="result__snippet">snippet</a>
                 </div>
               </div></body></html>
               """
             }}
        end
      end

      assert {:ok, [%Result{url: "https://b.example/"}]} =
               Long.Agent.Search.DuckDuckGo.search("q", http: stub)
    end

    test "retries html endpoint once on 202 (anti-bot challenge)" do
      this = self()

      stub = fn opts ->
        url = Keyword.fetch!(opts, :url)

        cond do
          String.contains?(url, "lite.duckduckgo.com") ->
            {:ok, %Req.Response{status: 200, body: ""}}

          String.contains?(url, "html.duckduckgo.com") ->
            prev =
              case :erlang.get({:ddg_html_calls}) do
                :undefined -> 0
                v -> v
              end

            n = prev + 1
            :erlang.put({:ddg_html_calls}, n)
            send(this, {:html_call, n})

            if n == 1 do
              {:ok, %Req.Response{status: 202, body: ""}}
            else
              {:ok,
               %Req.Response{
                 status: 200,
                 body: """
                 <html><body><div class="result">
                   <h2 class="result__title">
                     <a class="result__a"
                        href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fretried.example%2F">R</a>
                   </h2>
                 </div></body></html>
                 """
               }}
            end
        end
      end

      assert {:ok, [%Result{url: "https://retried.example/"}]} =
               Long.Agent.Search.DuckDuckGo.search("q",
                 http: stub,
                 sleeper: fn _ -> :ok end
               )

      assert_received {:html_call, 1}
      assert_received {:html_call, 2}
    end
  end

  describe "Google CDP transport" do
    defmodule CdpOk do
      def render_and_eval(_url, _js, _opts) do
        json =
          Jason.encode!([
            %{"title" => "Hexdocs", "url" => "https://hexdocs.pm/", "snippet" => "Docs"},
            %{"title" => "Elixir", "url" => "https://elixir-lang.org/", "snippet" => "Lang"}
          ])

        {:ok, json}
      end
    end

    defmodule CdpEmpty do
      def render_and_eval(_url, _js, _opts), do: {:ok, "[]"}
    end

    defmodule CdpUnreachable do
      def render_and_eval(_url, _js, _opts), do: {:error, :no_targets}
    end

    test "renders SERP via CDP and decodes JSON extractor output" do
      assert {:ok, results} =
               Long.Agent.Search.Google.search("phoenix",
                 transport: :cdp,
                 cdp_mod: CdpOk
               )

      assert Enum.map(results, & &1.url) == [
               "https://hexdocs.pm/",
               "https://elixir-lang.org/"
             ]
    end

    test "auto transport: CDP empty → falls back to HTTP" do
      http = fn _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: ~s(<a href="https://example.com/"><h3>From HTTP</h3></a>)
         }}
      end

      assert {:ok, [%Result{url: "https://example.com/"}]} =
               Long.Agent.Search.Google.search("q",
                 transport: :auto,
                 cdp_mod: CdpEmpty,
                 http: http
               )
    end

    test "auto transport: CDP unreachable → falls back to HTTP" do
      http = fn _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: ~s(<a href="https://fallback.example/"><h3>Fallback</h3></a>)
         }}
      end

      assert {:ok, [%Result{url: "https://fallback.example/"}]} =
               Long.Agent.Search.Google.search("q",
                 transport: :auto,
                 cdp_mod: CdpUnreachable,
                 http: http
               )
    end
  end

  describe "Brave.parse/1" do
    test "extracts legacy .snippet cards with a.h" do
      html = """
      <html><body>
        <div class="snippet">
          <a class="h" href="https://blog.example.com/post">
            <div class="title">Blog post title</div>
          </a>
          <div class="snippet-description">Short description here</div>
        </div>
      </body></html>
      """

      assert [
               %Result{
                 title: "Blog post title",
                 url: "https://blog.example.com/post",
                 snippet: "Short description here"
               }
             ] = Brave.parse(html)
    end

    test "extracts newer [data-type=web] layout" do
      html = """
      <html><body>
        <div data-type="web">
          <a href="https://example.org/x">
            <h3>Example x</h3>
          </a>
          <p>A paragraph snippet</p>
        </div>
      </body></html>
      """

      assert [%Result{title: "Example x", url: "https://example.org/x"}] = Brave.parse(html)
    end
  end

  describe "Search.search/2 with stubbed http" do
    test "merges results across engines with RRF, surfaces multi-source consensus" do
      stub = fn opts ->
        url = Keyword.fetch!(opts, :url)

        body =
          cond do
            String.contains?(url, "duckduckgo") ->
              ddg_html([
                {"https%3A%2F%2Fcommon.example%2F", "Common Site", "DDG snippet"},
                {"https%3A%2F%2Fonly-ddg.example%2F", "DDG Only", "alt"}
              ])

            String.contains?(url, "google.com") ->
              google_html([
                {"https://common.example/", "Common Site (Google)", "Google snippet"},
                {"https://only-google.example/", "Google Only", "x"}
              ])

            String.contains?(url, "brave.com") ->
              brave_html([
                {"https://common.example/", "Common Site (Brave)", "Brave snippet"}
              ])
          end

        {:ok, %Req.Response{status: 200, body: body}}
      end

      assert {:ok, %{results: results, status: status}} =
               Search.search("anything", http: stub, limit: 5)

      assert status == %{duckduckgo: :ok, google: :ok, brave: :ok}

      # The URL all three engines surfaced should rank #1.
      [top | _] = results
      assert top.url == "https://common.example/"
      assert Enum.sort(top.sources) == [:brave, :duckduckgo, :google]

      # And we should have a hit from every engine somewhere in the merge.
      all_urls = Enum.map(results, & &1.url)
      assert "https://only-ddg.example/" in all_urls
      assert "https://only-google.example/" in all_urls
    end

    test "partial failure: one engine errors, others still return results" do
      stub = fn opts ->
        url = Keyword.fetch!(opts, :url)

        cond do
          String.contains?(url, "duckduckgo") ->
            {:ok, %Req.Response{status: 403, body: "blocked"}}

          String.contains?(url, "google.com") ->
            {:ok,
             %Req.Response{
               status: 200,
               body: google_html([{"https://x.example/", "X", "x"}])
             }}

          String.contains?(url, "brave.com") ->
            {:ok,
             %Req.Response{
               status: 200,
               body: brave_html([{"https://y.example/", "Y", "y"}])
             }}
        end
      end

      assert {:ok, %{results: results, status: status}} =
               Search.search("anything", http: stub)

      assert status.duckduckgo == {:error, {:http_status, 403}}
      assert status.google == :ok
      assert status.brave == :ok

      urls = Enum.map(results, & &1.url)
      assert "https://x.example/" in urls
      assert "https://y.example/" in urls
    end

    test "dedupes by normalized URL (strips tracking params, trailing slash, www)" do
      stub = fn opts ->
        url = Keyword.fetch!(opts, :url)

        body =
          cond do
            String.contains?(url, "duckduckgo") ->
              ddg_html([
                {"https%3A%2F%2Fwww.example.com%2Fpage%2F%3Futm_source%3Dx", "A", "first"}
              ])

            String.contains?(url, "google.com") ->
              google_html([{"https://example.com/page", "B", "second"}])

            String.contains?(url, "brave.com") ->
              brave_html([])
          end

        {:ok, %Req.Response{status: 200, body: body}}
      end

      assert {:ok, %{results: [merged]}} = Search.search("q", http: stub)
      assert Enum.sort(merged.sources) == [:duckduckgo, :google]
    end

    test "empty query returns {:error, :empty_query}" do
      assert {:error, :empty_query} = Search.search("")
      assert {:error, :empty_query} = Search.search(nil)
    end
  end

  # ── HTML fixture helpers ────────────────────────────────────────────

  defp ddg_html(rows) do
    body =
      Enum.map_join(rows, "\n", fn {encoded_url, title, snippet} ->
        """
        <div class="result results_links">
          <h2 class="result__title">
            <a class="result__a" href="//duckduckgo.com/l/?uddg=#{encoded_url}">#{title}</a>
          </h2>
          <a class="result__snippet">#{snippet}</a>
        </div>
        """
      end)

    "<html><body><div class=\"results\">#{body}</div></body></html>"
  end

  defp google_html(rows) do
    body =
      Enum.map_join(rows, "\n", fn {url, title, snippet} ->
        """
        <div>
          <a href="#{url}"><h3>#{title}</h3></a>
          <div>#{snippet}</div>
        </div>
        """
      end)

    "<html><body>#{body}</body></html>"
  end

  defp brave_html(rows) do
    body =
      Enum.map_join(rows, "\n", fn {url, title, snippet} ->
        """
        <div class="snippet">
          <a class="h" href="#{url}"><div class="title">#{title}</div></a>
          <div class="snippet-description">#{snippet}</div>
        </div>
        """
      end)

    "<html><body>#{body}</body></html>"
  end
end
