defmodule Long.Agent.BrowserTest do
  use ExUnit.Case, async: true

  alias Long.Agent.Browser.{CDP, SimpHtml}

  describe "SimpHtml.simplify/2" do
    test "drops scripts/styles and collects interactive elements" do
      html = """
      <html>
        <head>
          <title>Hello</title>
          <style>body { color: red; }</style>
          <script>console.log("hi");</script>
        </head>
        <body>
          <h1>Hello world</h1>
          <p>Some text</p>
          <a href="/login">Sign in</a>
          <button>Submit</button>
          <input name="q" placeholder="search…" />
        </body>
      </html>
      """

      assert {:ok, %{title: "Hello", text: text, elements: elements}} = SimpHtml.simplify(html)

      assert text =~ "Hello world"
      assert text =~ "Some text"
      refute text =~ "console.log"
      refute text =~ "color: red"

      tags = Enum.map(elements, & &1.tag) |> Enum.sort()
      assert "a" in tags
      assert "button" in tags
      assert "input" in tags
    end

    test "elements carry the right text + attrs slice" do
      {:ok, %{elements: elements}} =
        SimpHtml.simplify(~s(<button id="b1" class="primary" data-other="x">Click me</button>))

      [b] = elements
      assert b.tag == "button"
      assert b.text == "Click me"
      assert b.attrs["id"] == "b1"
      assert b.attrs["class"] == "primary"
      refute Map.has_key?(b.attrs, "data-other")
    end

    test "respects ARIA role=button" do
      {:ok, %{elements: elements}} =
        SimpHtml.simplify(~s(<div role="button">Pseudo</div>))

      assert Enum.any?(elements, &(&1.attrs["role"] == "button"))
    end

    test "truncates very long text" do
      long = String.duplicate("word ", 5000)
      {:ok, %{text: text}} = SimpHtml.simplify("<p>#{long}</p>", max_chars: 100)
      assert text =~ "[…omitted…]"
      assert byte_size(text) < 200
    end
  end

  describe "SimpHtml.inject_ga_ids/1" do
    test "tags every interactive element with sequential ids" do
      html =
        ~s(<div><a href="/">Home</a><span>nope</span><button>Go</button><input /></div>)

      assert {:ok, out} = SimpHtml.inject_ga_ids(html)
      assert out =~ ~s(data-ga-id="0")
      assert out =~ ~s(data-ga-id="1")
      assert out =~ ~s(data-ga-id="2")
      # span isn't interactive
      refute out =~ ~s(<span data-ga-id)
    end
  end

  describe "CDP.targets/1" do
    test "decodes a successful /json response into Target structs" do
      http = fn opts ->
        assert opts[:url] == "http://test.local/json"

        {:ok,
         %Req.Response{
           status: 200,
           body: [
             %{
               "id" => "abc",
               "title" => "Tab",
               "url" => "https://example.com",
               "type" => "page",
               "webSocketDebuggerUrl" => "ws://test.local/devtools/page/abc"
             },
             %{"id" => "x", "title" => "Service", "url" => "...", "type" => "service_worker"}
           ]
         }}
      end

      assert {:ok, [%CDP.Target{id: "abc", url: "https://example.com", type: "page"}]} =
               CDP.targets(endpoint: "http://test.local", http: http)
    end

    test "surfaces HTTP errors" do
      http = fn _ -> {:ok, %Req.Response{status: 500, body: "boom"}} end
      assert {:error, {:http, 500, "boom"}} = CDP.targets(endpoint: "http://x", http: http)
    end
  end

  describe "CDP.call/4 transport plumbing" do
    test "encodes the JSON-RPC payload and surfaces the parsed response" do
      transport = fn ws_url, request, payload, _opts ->
        assert ws_url == "ws://test.local/devtools/page/abc"
        assert request["method"] == "Runtime.evaluate"

        assert request["params"] == %{
                 "expression" => "1+1",
                 "returnByValue" => true,
                 "awaitPromise" => true
               }

        assert is_binary(payload)

        {:ok, %{"id" => request["id"], "result" => %{"value" => 2}}}
      end

      assert {:ok, %{"value" => 2}} =
               CDP.evaluate("ws://test.local/devtools/page/abc", "1+1", transport: transport)
    end

    test "propagates CDP errors verbatim" do
      transport = fn _, _, _, _ ->
        {:ok, %{"error" => %{"code" => -32000, "message" => "Cannot find context"}}}
      end

      assert {:error, %{"code" => -32000, "message" => "Cannot find context"}} =
               CDP.call("ws://x/y", "Page.navigate", %{"url" => "https://example.com"},
                 transport: transport
               )
    end
  end
end
