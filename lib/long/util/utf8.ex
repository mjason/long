defmodule Long.Util.Utf8 do
  @moduledoc """
  UTF-8-safe helpers. Two recurring problems we hit when ingesting
  bytes from HTTP / shell / decoded media:

  - **Mid-character truncation**: `binary_part(b, 0, N)` cuts at a
    byte boundary, often landing in the middle of a multibyte UTF-8
    sequence. The resulting binary is invalid UTF-8 and `Jason.encode!`
    rejects it with `invalid byte 0xE7 in <<…>>`.

  - **Garbage bytes in otherwise-text payloads**: a download claims to
    be UTF-8 but contains stray illegal bytes. We need a "make this
    safe to serialize" pass.

  Both surfaces use `:unicode.characters_to_binary/3`, which is the
  canonical OTP entry point for validating + repairing UTF-8 data.
  """

  @doc """
  Truncate `bin` to at most `max_bytes`, ending on a complete UTF-8
  character boundary. Falls back to the empty string on bad input.
  Non-binary input is returned unchanged.
  """
  @spec safe_truncate(binary(), pos_integer()) :: binary()
  def safe_truncate(bin, max_bytes) when is_binary(bin) and byte_size(bin) <= max_bytes, do: bin

  def safe_truncate(bin, max_bytes) when is_binary(bin) and is_integer(max_bytes) and max_bytes > 0 do
    bin
    |> binary_part(0, max_bytes)
    |> trim_to_valid()
  end

  def safe_truncate(other, _), do: other

  @doc """
  Like `safe_truncate/2` but keeps the head and tail with an ellipsis
  marker in the middle. Useful for long stdout/stderr captures and
  large HTML bodies.
  """
  @spec head_tail(binary(), pos_integer(), String.t()) :: binary()
  def head_tail(bin, max_bytes, marker \\ "\n\n[…truncated…]\n\n")

  def head_tail(bin, max_bytes, _marker) when is_binary(bin) and byte_size(bin) <= max_bytes,
    do: bin

  def head_tail(bin, max_bytes, marker)
      when is_binary(bin) and is_integer(max_bytes) and max_bytes > 0 do
    half = div(max_bytes, 2)
    head = bin |> binary_part(0, half) |> trim_to_valid()
    tail = bin |> binary_part(byte_size(bin) - half, half) |> trim_leading_to_valid()
    head <> marker <> tail
  end

  def head_tail(other, _, _), do: other

  @doc """
  Coerce a value into a Jason-encodable shape: any embedded binary
  that isn't valid UTF-8 has illegal bytes replaced with U+FFFD.
  Maps and lists are walked recursively; atoms, numbers, booleans
  and nil pass through.
  """
  def sanitize(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {sanitize(k), sanitize(v)} end)
  end

  def sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)

  def sanitize(bin) when is_binary(bin) do
    case :unicode.characters_to_binary(bin, :utf8, :utf8) do
      result when is_binary(result) -> result
      {:error, ok, _} -> ok <> "�"
      {:incomplete, ok, _} -> ok <> "�"
    end
  end

  def sanitize(other), do: other

  # ── internals ────────────────────────────────────────────────────────

  defp trim_to_valid(bin) do
    case :unicode.characters_to_binary(bin, :utf8, :utf8) do
      result when is_binary(result) ->
        result

      {:incomplete, ok, _} ->
        ok

      {:error, ok, _} ->
        ok
    end
  end

  defp trim_leading_to_valid(bin) when byte_size(bin) == 0, do: bin

  defp trim_leading_to_valid(bin) do
    case :unicode.characters_to_binary(bin, :utf8, :utf8) do
      result when is_binary(result) ->
        result

      {:error, _, _} ->
        <<_::8, rest::binary>> = bin
        trim_leading_to_valid(rest)

      {:incomplete, ok, _} ->
        ok
    end
  end
end
