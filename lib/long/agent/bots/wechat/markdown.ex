defmodule Long.Agent.Bots.Wechat.Markdown do
  @moduledoc """
  WeChat-side markdown sanitizer. Mirrors the rules in Tencent's
  `Tencent/openclaw-weixin` `markdown-filter.ts`: WeChat's chat client
  renders a generous markdown subset — code fences, inline code,
  bold (`**`), tables, horizontal rules, H1–H4, blockquote content,
  links, lists — so we leave those alone. We only strip what the
  client either ignores or renders badly:

    * `![alt](url)` images — removed entirely
    * `#####` / `######` H5/H6 — markers stripped, content kept
    * `>` blockquote marker — stripped, content kept
    * `~~text~~` strikethrough — markers stripped, content kept
    * `*中文*` / `_中文_` / `***中文***` / `___中文___` — markers stripped
      when content contains a CJK code point (WeChat doesn't render
      italic over CJK well)

  On top of that we strip a few application-specific framing tokens
  the LLM sometimes emits (`<thinking>`, `<tool_use>` blocks, etc.)
  that should never reach the user.
  """

  @tag_patterns [
    ~r/<thinking>.*?<\/thinking>/s,
    ~r/<tool_use>.*?<\/tool_use>/s,
    ~r/<file_content>.*?<\/file_content>/s
  ]

  @summary_tags ~r/<\/?summary>/

  @turn_header ~r/^\s*LLM Running \(Turn \d+\) \.{3}\s*$/m

  @tool_call_line ~r/^\s*🛠️\s*[A-Za-z_][A-Za-z0-9_]*\(.*$/m

  # CJK Unified Ideographs + Hangul + CJK Compat Ideographs (matches
  # the official filter's `containsCJK` set).
  @cjk_class "\\x{2E80}-\\x{9FFF}\\x{AC00}-\\x{D7AF}\\x{F900}-\\x{FAFF}"

  # Code fences (``` … ```, incl. an unclosed trailing one) and inline code
  # (`…`) pass through verbatim — mirrors the official filter's `fence` state,
  # so markdown-like characters inside code are never mangled.
  @fence_re ~r/```.*?(?:```|\z)/s
  @inline_re ~r/`[^`\n]+`/

  @doc """
  Apply the full WeChat-tuned cleanup: strip our own framing tokens,
  then run the markdown sanitizer.
  """
  def clean(text) when is_binary(text) do
    text
    |> String.replace(@turn_header, "")
    |> String.replace(@tool_call_line, "")
    |> strip_xml_tags()
    |> String.replace(@summary_tags, "")
    |> strip_markdown()
    |> collapse_blank_lines()
    |> String.trim()
  end

  @doc "Strip the markdown subset WeChat doesn't render or renders badly."
  def strip_markdown(text) when is_binary(text) do
    # Code fences and inline code pass through verbatim (the official filter's
    # `fence` state); only the plain segments between them are stripped, so
    # `~~`, `*中文*`, `#####`, `>` inside code survive untouched.
    protect(text, @fence_re, fn outside ->
      protect(outside, @inline_re, &strip_plain/1)
    end)
  end

  # Run `fun` only on the segments that DON'T match `re`; keep matches verbatim.
  defp protect(text, re, fun) do
    re
    |> Regex.split(text, include_captures: true, trim: false)
    |> Enum.map_join("", fn part ->
      if Regex.match?(re, part), do: part, else: fun.(part)
    end)
  end

  defp strip_plain(text) do
    text
    |> remove_images()
    |> strip_strikethrough()
    |> strip_cjk_bold_italic("*")
    |> strip_cjk_bold_italic("_")
    |> strip_cjk_italic("*")
    |> strip_cjk_italic("_")
    |> strip_deep_headings()
    |> strip_blockquotes()
  end

  # ── Internals ────────────────────────────────────────────────────────

  defp strip_xml_tags(text) do
    Enum.reduce(@tag_patterns, text, fn re, acc -> String.replace(acc, re, "") end)
  end

  defp collapse_blank_lines(text), do: Regex.replace(~r/\n{3,}/, text, "\n\n")

  defp remove_images(text), do: Regex.replace(~r/!\[[^\]]*\]\([^)]*\)/, text, "")

  defp strip_strikethrough(text) do
    Regex.replace(~r/~~([^~\n]+)~~/u, text, "\\1")
  end

  defp strip_deep_headings(text) do
    Regex.replace(~r/^\#{5,6}\s+/m, text, "")
  end

  defp strip_blockquotes(text), do: Regex.replace(~r/^\s*>\s?/m, text, "")

  # `***中文***` / `___中文___` — bold-italic over CJK: drop markers.
  # Non-CJK content keeps markers.
  defp strip_cjk_bold_italic(text, ch) do
    triple = String.duplicate(Regex.escape(ch), 3)
    re = Regex.compile!("#{triple}([^#{Regex.escape(ch)}\\n]+?)#{triple}", "u")

    Regex.replace(re, text, fn full, content ->
      if cjk?(content), do: content, else: full
    end)
  end

  # `*中文*` / `_中文_` — italic over CJK. Use lookarounds so we don't
  # eat `**bold**` or `__bold__` (`*` preceded or followed by another
  # `*` is part of bold and must be left alone).
  defp strip_cjk_italic(text, ch) do
    esc = Regex.escape(ch)
    re = Regex.compile!("(?<!#{esc})#{esc}(?!#{esc})([^#{esc}\\n]+?)(?<!#{esc})#{esc}(?!#{esc})", "u")

    Regex.replace(re, text, fn full, content ->
      if cjk?(content), do: content, else: full
    end)
  end

  defp cjk?(text) do
    case Regex.compile("[#{@cjk_class}]", "u") do
      {:ok, re} -> Regex.match?(re, text)
      _ -> false
    end
  end
end
