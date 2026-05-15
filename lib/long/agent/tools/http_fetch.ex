defmodule Long.Agent.Tools.HttpFetch do
  @moduledoc """
  Simple HTTP fetcher. The everyday "go look at this URL" tool — no Chrome
  required, no Python deps needed.

  Use this instead of `web_scan` when you don't need real-browser behaviour
  (JS execution, login state, clicks). Use this instead of `code_run` with
  `urllib`/`requests` when you just need to read a page; saves an
  `uv add` round-trip and the response goes through the same SimpHtml
  pipeline the browser tools use.
  """

  @behaviour Long.Agent.Tool

  alias Long.Agent.{StepOutcome, Tool, ToolContext}
  alias Long.Agent.Browser.SimpHtml
  alias Long.Util.Utf8

  @default_timeout 15_000
  @max_body_bytes 2_000_000

  @impl true
  def name, do: "http_fetch"

  @impl true
  def schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => name(),
        "description" =>
          "GET (or POST/PUT/DELETE) an HTTP URL. For HTML responses, returns " <>
            "simplified text + interactive element list (same shape as web_scan). " <>
            "For JSON or text, returns the raw body. Use this for vanilla scraping; " <>
            "use web_scan when you need a real browser (Chrome must be running).",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "url" => %{"type" => "string"},
            "method" => %{
              "type" => "string",
              "enum" => ["GET", "POST", "PUT", "DELETE", "HEAD"],
              "default" => "GET"
            },
            "headers" => %{
              "type" => "object",
              "description" => "Additional request headers as a flat string map."
            },
            "body" => %{"type" => "string", "description" => "Raw request body for POST/PUT."},
            "json" => %{"description" => "JSON body for POST/PUT (overrides `body`)."},
            "raw" => %{
              "type" => "boolean",
              "default" => false,
              "description" => "Skip HTML simplification, return raw body bytes."
            }
          },
          "required" => ["url"]
        }
      }
    }
  end

  @method_map %{
    "GET" => :get,
    "POST" => :post,
    "PUT" => :put,
    "DELETE" => :delete,
    "HEAD" => :head
  }

  @impl true
  def run(args, %ToolContext{}) do
    url = args["url"] || ""

    if url == "" do
      Tool.emit(
        "[Status] ❌ url is required\n",
        StepOutcome.cont(%{"status" => "error", "msg" => "url required"})
      )
    else
      Tool.emit("[Action] http_fetch #{args["method"] || "GET"} #{url}\n", do_fetch(args))
    end
  end

  defp do_fetch(args) do
    req_opts =
      [
        method: parse_method(args["method"]),
        url: args["url"],
        receive_timeout: args["timeout_ms"] || @default_timeout,
        max_redirects: 5,
        retry: false
      ]
      |> maybe_put(:headers, args["headers"])
      |> maybe_put(:body, args["body"])
      |> maybe_put(:json, args["json"])

    case Req.request(req_opts) do
      {:ok, %Req.Response{} = resp} ->
        build_payload(args, resp)

      {:error, %{__exception__: true} = e} ->
        StepOutcome.cont(%{"status" => "error", "msg" => Exception.message(e)})

      {:error, e} ->
        StepOutcome.cont(%{"status" => "error", "msg" => inspect(e)})
    end
  end

  # String.to_existing_atom would still allow arbitrary atoms; whitelist is safer.
  defp parse_method(nil), do: :get
  defp parse_method(m) when is_binary(m), do: Map.get(@method_map, String.upcase(m), :get)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp build_payload(args, %Req.Response{status: status, body: body} = resp) do
    content_type = Req.Response.get_header(resp, "content-type") |> List.first()
    text = to_text(body, @max_body_bytes)

    base = %{
      "status" => if(status >= 200 and status < 400, do: "success", else: "error"),
      "http_status" => status,
      "content_type" => content_type,
      "url" => args["url"]
    }

    cond do
      args["raw"] == true -> StepOutcome.cont(Map.put(base, "body", text))
      html?(content_type, text) -> simplified_or_raw(base, text)
      true -> StepOutcome.cont(Map.put(base, "body", text))
    end
  end

  defp simplified_or_raw(base, text) do
    case SimpHtml.simplify(text) do
      {:ok, s} ->
        StepOutcome.cont(
          base
          |> Map.put("title", s.title)
          |> Map.put("text", s.text)
          |> Map.put("elements", s.elements)
        )

      _ ->
        StepOutcome.cont(Map.put(base, "body", text))
    end
  end

  defp html?(content_type, body) when is_binary(content_type) do
    ct = String.downcase(content_type)
    String.contains?(ct, "html") or (String.contains?(ct, "text") and looks_like_html?(body))
  end

  defp html?(_, body), do: looks_like_html?(body)

  defp looks_like_html?(body) when is_binary(body) do
    head = body |> String.slice(0, 200) |> String.downcase()
    String.contains?(head, "<html") or String.contains?(head, "<!doctype html")
  end

  defp looks_like_html?(_), do: false

  defp to_text(b, max) when is_binary(b) and byte_size(b) > max do
    Utf8.safe_truncate(b, max) <> "\n\n[…truncated…]"
  end

  defp to_text(b, _) when is_binary(b), do: b

  defp to_text(b, _), do: inspect(b)
end
