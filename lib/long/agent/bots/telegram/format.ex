defmodule Long.Agent.Bots.Telegram.Format do
  @moduledoc """
  Turns the assistant's raw text into something Telegram can render
  natively, in HTML mode.

  Why HTML and not MarkdownV2: the LLM emits CommonMark-flavoured
  markdown (`**bold**`, `*italic*`, `` `code` ``, ` ``` ` blocks), but
  Telegram's MarkdownV2 uses *different* delimiters (`*bold*`, `_italic_`)
  AND requires escaping a dozen punctuation chars EVERYWHERE — including
  literal periods, dashes, parens. Trying to translate the model's
  markdown into MarkdownV2 is more error-prone than the HTML detour.

  HTML mode supports a small whitelist: `<b>`, `<i>`, `<u>`, `<s>`,
  `<code>`, `<pre>`, `<a href>`, blockquote, spoiler. We map the
  common LLM-markdown patterns into this set and let the rest pass
  through as plain text.

  Escaping: only `<`, `>`, `&` need to be escaped for HTML mode. We
  carve the input into "code" vs "plain" segments first, then escape
  each segment exactly once (so `<html>` inside a code block survives
  as literal `&lt;html&gt;`, and the tags we emit are never themselves
  mangled).
  """

  # Telegram caps a single sendMessage at 4096 codepoints — slightly
  # under to leave room for any per-chunk header / suffix if added later.
  @chunk_size 4000

  # Order matters: fenced ``` blocks before inline `code`, because a
  # fenced block can contain backticks that would otherwise be parsed
  # as inline. Both come before bold so `**` inside code stays literal.
  @fenced_re ~r/```[^\n]*\n?(.*?)```/s
  @inline_re ~r/`([^`\n]+?)`/
  @bold_re ~r/\*\*([^*\n]+?)\*\*/

  @doc """
  Convert a markdown-ish string into Telegram-HTML.

  Pipeline:
    1. Extract ` ``` ` fenced code blocks; everything outside continues
       to step 2, the block bodies are escaped + wrapped in `<pre>…</pre>`.
    2. Same for inline `` `code` `` → `<code>…</code>`.
    3. Remaining plain segments get `<`, `>`, `&` escaped and
       `**bold**` → `<b>bold</b>` applied.
  """
  @spec to_html(String.t() | nil) :: String.t()
  def to_html(nil), do: ""
  def to_html(""), do: ""

  def to_html(text) when is_binary(text) do
    [{:raw, text}]
    |> transform_matches(@fenced_re, &render_pre/1)
    |> transform_matches(@inline_re, &render_code/1)
    |> assemble()
  end

  @doc """
  Split a (formatted) string into chunks each ≤ #{@chunk_size}
  codepoints. Prefers splitting at blank-line paragraph boundaries;
  falls back to single-line and then hard-cut.

  Note: no awareness of HTML tag boundaries — if a single `<pre>`
  block exceeds the chunk size it will be hard-cut and Telegram will
  reject the second half. Long fenced blocks are rare in chat
  replies; revisit if they show up in practice.
  """
  @spec chunks(String.t()) :: [String.t()]
  def chunks(""), do: []

  def chunks(text) when is_binary(text) do
    if String.length(text) <= @chunk_size do
      [text]
    else
      do_chunks(text, [])
    end
  end

  # ── Segment walk ─────────────────────────────────────────────────
  #
  # We represent the in-flight text as a list of `{:raw, binary}` (still
  # markdown-ish, will be escape+bold-converted at the end) and
  # `{:html, binary}` (already final HTML, do not touch). Each
  # `transform_matches/3` pass splits any remaining `:raw` segments on
  # the given regex, converting the matches with `render` and leaving
  # the gaps as `:raw` for the next pass.

  defp transform_matches(pieces, regex, render) do
    Enum.flat_map(pieces, fn
      {:html, _} = done -> [done]
      {:raw, str} -> split_raw(str, regex, render)
    end)
  end

  # `Regex.split(include_captures: true)` returns the full matches
  # interleaved with the gaps. We re-extract the capture group from
  # each match via the same regex so `render` only ever sees the body
  # (i.e. without backticks / fences).
  defp split_raw(str, regex, render) do
    regex
    |> Regex.split(str, include_captures: true)
    |> Enum.flat_map(fn part ->
      case Regex.run(regex, part, capture: :all_but_first) do
        [body] -> [{:html, render.(body)}]
        nil when part == "" -> []
        nil -> [{:raw, part}]
      end
    end)
  end

  # `` ```elixir\nx = 1\n``` `` → ``<pre>x = 1</pre>``. Trim the
  # newlines around the body (a leading newline follows the language
  # tag, a trailing one precedes the closing fence).
  defp render_pre(body), do: "<pre>" <> escape_html(String.trim(body, "\n")) <> "</pre>"
  defp render_code(body), do: "<code>" <> escape_html(body) <> "</code>"

  # Concatenate the pieces: raw segments get HTML-escaped + bold pass,
  # html segments pass through verbatim. Bold runs per-raw-segment (NOT
  # on the joined string) so `**` inside an already-rendered
  # `<code>…</code>` stays literal. Trade-off: a `**…**` span that
  # straddles an inline code (e.g. ``Use **`mix test`**``) won't render
  # as bold, only the code part will. Rare in chat replies.
  defp assemble(pieces) do
    Enum.map_join(pieces, "", fn
      {:html, str} -> str
      {:raw, str} -> str |> escape_html() |> convert_bold()
    end)
  end

  defp escape_html(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # `**bold**` → `<b>bold</b>`. The `[^*\n]+?` body deliberately
  # rejects nested `*` (so `**a*b**` stays literal) and any newline,
  # matching common LLM output. Lone `*` (bullet markers) survive
  # because the regex requires the doubled delimiter on both sides.
  defp convert_bold(text), do: Regex.replace(@bold_re, text, "<b>\\1</b>")

  # ── Chunking ─────────────────────────────────────────────────────

  defp do_chunks("", acc), do: Enum.reverse(acc)

  defp do_chunks(text, acc) do
    if String.length(text) <= @chunk_size do
      do_chunks("", [text | acc])
    else
      {head, tail} = split_one_chunk(text)
      do_chunks(tail, [head | acc])
    end
  end

  # Pick the cleanest split point ≤ chunk_size: blank line, then
  # single newline, then a hard slice. Whichever fires first wins.
  defp split_one_chunk(text) do
    window = String.slice(text, 0, @chunk_size)

    cond do
      idx = last_index(window, "\n\n") -> hard_split(text, idx + 2)
      idx = last_index(window, "\n") -> hard_split(text, idx + 1)
      true -> hard_split(text, @chunk_size)
    end
  end

  # Index of the LAST occurrence of `needle` in `window`. `:binary.matches`
  # returns byte offsets which line up with codepoint offsets for our
  # ASCII needles (`\n`, `\n\n`).
  defp last_index(window, needle) do
    case :binary.matches(window, needle) do
      [] -> nil
      pairs -> pairs |> List.last() |> elem(0)
    end
  end

  defp hard_split(text, idx) do
    head = text |> String.slice(0, idx) |> String.trim_trailing()
    tail = text |> String.slice(idx..-1//1) |> String.trim_leading()
    {head, tail}
  end
end
