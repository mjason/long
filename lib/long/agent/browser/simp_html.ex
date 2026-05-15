defmodule Long.Agent.Browser.SimpHtml do
  @moduledoc """
  HTML simplifier — replaces the 873-line Python `simphtml.py` with a much
  thinner Floki-based pass.

  Given a raw HTML document, returns:

      %{
        title: "...",
        text:  "flattened visible-text rendering",
        elements: [
          %{id: 0, tag: "a",      text: "Sign in", attrs: %{"href" => "/login"}},
          %{id: 1, tag: "button", text: "Submit",  attrs: %{}},
          ...
        ]
      }

  Each interactive element is given a stable sequential `id` and the same
  id is injected as `data-ga-id="N"` into the live DOM by the
  `Long.Agent.Tools.WebScan` flow, so the agent can `click()` element N by
  selector `[data-ga-id="N"]`.

  This is **not** a faithful port of `simphtml.py` — the Python version
  also computes accessibility roles, ARIA labels, floating-element
  filtering, and DOM-position-based ranking. We cover the 80% case and
  leave the long tail for follow-up.
  """

  @interactive_tags ~w(a button input select textarea label summary [role=button])
  @stripped_tags ~w(script style noscript template svg)

  @doc """
  Simplify a raw HTML document. Returns `{:ok, %{...}}`.
  """
  def simplify(html, opts \\ []) when is_binary(html) do
    max_chars = Keyword.get(opts, :max_chars, 8_000)

    case Floki.parse_document(html) do
      {:ok, doc} ->
        cleaned =
          doc
          |> strip_tags(@stripped_tags)
          |> strip_comments()

        title = title_of(cleaned)
        elements = collect_elements(cleaned)
        text = render_text(cleaned, max_chars)

        {:ok, %{title: title, text: text, elements: elements}}

      {:error, e} ->
        {:error, e}
    end
  end

  @doc """
  Inject a `data-ga-id="N"` attribute into every interactive element of
  the page so the agent can address them by id. Returns the rewritten
  HTML string.

  Pure: same input ⇒ same output.
  """
  def inject_ga_ids(html) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        {tagged, _next_id} = traverse_and_tag(doc, 0)
        {:ok, Floki.raw_html(tagged)}

      {:error, e} ->
        {:error, e}
    end
  end

  # ── tagging traversal ─────────────────────────────────────────────────────

  defp traverse_and_tag(nodes, next_id) when is_list(nodes) do
    Enum.reduce(nodes, {[], next_id}, fn node, {acc, id_acc} ->
      {tagged, new_id} = traverse_and_tag(node, id_acc)
      {acc ++ [tagged], new_id}
    end)
  end

  defp traverse_and_tag({tag, attrs, children}, next_id) do
    {new_attrs, next_id} =
      if interactive?(tag, attrs) do
        {attrs ++ [{"data-ga-id", Integer.to_string(next_id)}], next_id + 1}
      else
        {attrs, next_id}
      end

    {tagged_children, next_id} =
      Enum.reduce(children, {[], next_id}, fn child, {acc, id_acc} ->
        {tagged, new_id} = traverse_and_tag(child, id_acc)
        {acc ++ [tagged], new_id}
      end)

    {{tag, new_attrs, tagged_children}, next_id}
  end

  defp traverse_and_tag(node, next_id), do: {node, next_id}

  # ── element extraction ────────────────────────────────────────────────────

  defp collect_elements(doc) do
    doc
    |> Floki.find(Enum.join(@interactive_tags, ", "))
    |> Enum.with_index()
    |> Enum.map(fn {{tag, attrs, children}, idx} ->
      %{
        id: idx,
        tag: tag,
        text: node_text(children) |> String.trim() |> truncate(100),
        attrs: keep_attrs(attrs)
      }
    end)
  end

  defp interactive?(tag, _attrs) when tag in ~w(a button input select textarea label summary),
    do: true

  defp interactive?(_tag, attrs) do
    case List.keyfind(attrs, "role", 0) do
      {"role", role} when role in ~w(button link checkbox radio menuitem option) -> true
      _ -> false
    end
  end

  defp keep_attrs(attrs) do
    Enum.into(attrs, %{}, fn {k, v} -> {k, v} end)
    |> Map.take(~w(href value name placeholder type id class role aria-label data-ga-id))
  end

  # ── text rendering ────────────────────────────────────────────────────────

  defp render_text(doc, max_chars) do
    doc
    |> Floki.text(deep: true, sep: " ")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n[\s\n]*/, "\n")
    |> String.trim()
    |> truncate(max_chars)
  end

  defp title_of(doc) do
    case Floki.find(doc, "title") do
      [] -> nil
      [first | _] -> first |> Floki.text() |> String.trim()
    end
  end

  defp node_text(children), do: Floki.text({"div", [], children}, sep: " ")

  defp strip_tags(doc, tags) do
    Enum.reduce(tags, doc, fn tag, acc -> Floki.filter_out(acc, tag) end)
  end

  defp strip_comments(doc) do
    Floki.traverse_and_update(doc, fn
      {:comment, _} -> nil
      node -> node
    end)
  end

  defp truncate(nil, _), do: ""

  defp truncate(s, max) when byte_size(s) > max do
    Long.Util.Utf8.head_tail(s, max, "\n\n[…omitted…]\n\n")
  end

  defp truncate(s, _), do: s
end
