defmodule Long.Jido.Tools.HttpFetch do
  @moduledoc """
  Jido.Action port of `Long.Agent.Tools.HttpFetch`. Reuses our
  `Long.Agent.Browser.SimpHtml` for the HTML simplification pass — the
  jido side only changes the action wrapper, not the underlying logic.
  """

  use Jido.Action,
    name: "http_fetch",
    description:
      "GET an HTTP URL. Returns simplified text + clickable element list when " <>
        "the response is HTML; raw body otherwise.",
    category: "web",
    tags: ["http", "fetch"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        url: Zoi.string(description: "Absolute URL to fetch"),
        method:
          Zoi.string(description: "HTTP method: GET | POST | PUT | DELETE | HEAD")
          |> Zoi.optional()
          |> Zoi.default("GET")
      })

  alias Long.Agent.Browser.SimpHtml

  @default_timeout 15_000
  @max_body_bytes 1_500_000

  @method_map %{
    "GET" => :get,
    "POST" => :post,
    "PUT" => :put,
    "DELETE" => :delete,
    "HEAD" => :head
  }

  @impl true
  def run(params, _ctx) do
    url = params[:url] || params["url"]
    method = parse_method(params[:method] || params["method"])

    case Req.request(method: method, url: url, retry: false, receive_timeout: @default_timeout) do
      {:ok, %Req.Response{status: status, body: body} = resp} ->
        body_text = to_text(body)
        ct = Req.Response.get_header(resp, "content-type") |> List.first()

        payload =
          if html?(ct, body_text) do
            case SimpHtml.simplify(body_text) do
              {:ok, s} ->
                %{
                  status: status,
                  url: url,
                  title: s.title,
                  text: s.text,
                  elements: s.elements
                }

              _ ->
                %{status: status, url: url, body: body_text}
            end
          else
            %{status: status, url: url, body: body_text}
          end

        {:ok, payload}

      {:error, %{__exception__: true} = e} ->
        {:error, "http_fetch failed: #{Exception.message(e)}"}

      {:error, e} ->
        {:error, "http_fetch failed: #{inspect(e)}"}
    end
  end

  # Whitelist beats `String.to_atom` (atom-table leak) or
  # `String.to_existing_atom` (still allows non-method atoms like `:get`
  # to appear just because some other module happened to declare them).
  defp parse_method(nil), do: :get
  defp parse_method(m) when is_atom(m), do: m
  defp parse_method(m) when is_binary(m), do: Map.get(@method_map, String.upcase(m), :get)

  defp to_text(b) when is_binary(b) and byte_size(b) > @max_body_bytes do
    binary_part(b, 0, @max_body_bytes) <> "\n\n[…truncated…]"
  end

  defp to_text(b) when is_binary(b), do: b
  defp to_text(b), do: inspect(b)

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
end
