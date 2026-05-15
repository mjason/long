defmodule Long.Agent.Search.Brave do
  @moduledoc """
  Brave Search SERP HTML parser. Brave doesn't redirect outbound links
  (unlike DDG/Google) so the `href` we pull is the canonical URL.

  Two layouts in the wild:
    * `.snippet` cards with `a.h` (legacy)
    * `[data-type=web] a` (newer Web Discovery rebrand)
  """

  alias Long.Agent.Search.{Http, Result, Text}

  @endpoint "https://search.brave.com/search"

  @spec search(String.t(), keyword()) :: {:ok, [Result.t()]} | {:error, term()}
  def search(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 10)
    Http.get_serp(@endpoint, %{q: query, source: "web"}, &parse(&1, limit), opts)
  end

  @doc false
  def parse(html, limit \\ 10) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, doc} -> doc |> extract() |> Enum.take(limit)
      {:error, _} -> []
    end
  end

  defp extract(doc) do
    (Floki.find(doc, ".snippet") ++ Floki.find(doc, "[data-type=web]"))
    |> Enum.flat_map(&row/1)
    |> Enum.uniq_by(& &1.url)
  end

  defp row(node) do
    anchor =
      case Floki.find(node, "a.h") do
        [a | _] -> a
        _ -> node |> Floki.find("a[href^=http]") |> List.first()
      end

    case anchor do
      nil ->
        []

      a ->
        case a |> Floki.attribute("href") |> List.first() || "" do
          "" ->
            []

          url ->
            title =
              node
              |> Floki.find(".title, h3, h4")
              |> Floki.text()
              |> Text.clean()
              |> default_title(a)

            snippet =
              node
              |> Floki.find(".snippet-description, .snippet-content, p")
              |> Floki.text()
              |> Text.clean()

            [%Result{title: title, url: url, snippet: snippet}]
        end
    end
  end

  defp default_title("", anchor), do: anchor |> Floki.text() |> Text.clean()
  defp default_title(t, _), do: t
end
