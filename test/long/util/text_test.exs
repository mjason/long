defmodule Long.Util.TextTest do
  use ExUnit.Case, async: true

  alias Long.Util.Text

  describe "preview/2,3" do
    test "passes through when under the cap" do
      assert "short" == Text.preview("short", 40)
    end

    test "truncates by codepoint count and appends ellipsis" do
      assert "0123456789…" == Text.preview("0123456789ABCDEF", 10)
    end

    test "CJK characters are counted as 1 each, not 3 bytes" do
      # 11 CJK chars (33 bytes). Cap at 10 codepoints → keep first 10 + …
      assert "一二三四五六七八九十…" == Text.preview("一二三四五六七八九十百", 10)
    end

    test "custom ellipsis" do
      assert "abc..." == Text.preview("abcdef", 3, "...")
    end

    test "non-binary passes through to_string" do
      assert "42" == Text.preview(42, 10)
    end
  end

  describe "first_line/1" do
    test "single-line strings pass through" do
      assert "single" == Text.first_line("single")
    end

    test "takes everything before the first newline" do
      assert "first" == Text.first_line("first\nsecond\nthird")
    end
  end
end
