defmodule Long.Util.Text do
  @moduledoc false

  @default_ellipsis "…"

  @doc """
  Codepoint-aware truncate-with-ellipsis for user-facing previews
  (chat lines, `/status` output, tool-call argument summaries).
  Counts Unicode characters, not bytes, so a 40-char preview of CJK
  text shows 40 characters, not 13.

  `byte_size`-based truncation belongs in `Long.Util.Utf8.safe_truncate/2`
  for size-bounded storage / API payloads.
  """
  @spec preview(String.t() | term(), pos_integer(), String.t()) :: String.t()
  def preview(text, max_chars, ellipsis \\ @default_ellipsis)

  def preview(text, max_chars, ellipsis) when is_binary(text) and is_integer(max_chars) and max_chars > 0 do
    if String.length(text) > max_chars do
      String.slice(text, 0, max_chars) <> ellipsis
    else
      text
    end
  end

  def preview(other, _, _), do: to_string(other)

  @doc "First non-empty line of a string, or the whole string when there's only one line."
  @spec first_line(String.t()) :: String.t()
  def first_line(text) when is_binary(text) do
    case String.split(text, "\n", parts: 2) do
      [first | _] -> first
      _ -> text
    end
  end
end
