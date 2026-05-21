defmodule Long.Agent.Bots.Telegram.FormatTest do
  use ExUnit.Case, async: true

  alias Long.Agent.Bots.Telegram.Format

  describe "to_html/1 — basic escaping" do
    test "escapes the three HTML danger chars" do
      assert Format.to_html("a < b & c > d") == "a &lt; b &amp; c &gt; d"
    end

    test "passes plain prose through unchanged" do
      assert Format.to_html("Hello, world.") == "Hello, world."
    end

    test "nil / empty are no-ops" do
      assert Format.to_html(nil) == ""
      assert Format.to_html("") == ""
    end
  end

  describe "to_html/1 — markdown conversion" do
    test "**bold** becomes <b>" do
      assert Format.to_html("hello **world**") == "hello <b>world</b>"
    end

    test "inline `code` becomes <code>" do
      assert Format.to_html("call `String.trim/1` first") ==
               "call <code>String.trim/1</code> first"
    end

    test "fenced ``` block becomes <pre>" do
      input = "before\n```\nfoo\nbar\n```\nafter"
      assert Format.to_html(input) =~ "<pre>foo\nbar</pre>"
    end

    test "fenced block with language fence drops the lang word" do
      input = "```elixir\nx = 1\n```"
      assert Format.to_html(input) == "<pre>x = 1</pre>"
    end

    test "bold inside code stays literal (no nesting)" do
      assert Format.to_html("`**not bold**`") == "<code>**not bold**</code>"
    end

    test "lone asterisks (bullet markers) survive untouched" do
      assert Format.to_html("* item one\n* item two") == "* item one\n* item two"
    end

    test "HTML inside code block is escaped but preserved as text" do
      input = "```\n<html>\n```"
      assert Format.to_html(input) == "<pre>&lt;html&gt;</pre>"
    end

    test "interleaved code + bold + escaping" do
      # Bold runs per-raw-segment, so a `**…**` span split by an inline
      # `<code>` won't render as bold — the `**` markers stay literal
      # on either side. Acceptable trade for keeping `**` inside code
      # blocks unescaped.
      input = "Use **`mix test`** to run < 100 tests."

      assert Format.to_html(input) ==
               "Use **<code>mix test</code>** to run &lt; 100 tests."
    end
  end

  describe "chunks/1" do
    test "short text is one chunk" do
      assert Format.chunks("hi") == ["hi"]
    end

    test "empty string yields no chunks" do
      assert Format.chunks("") == []
    end

    test "splits at paragraph boundary when over the cap" do
      para1 = String.duplicate("a", 3500)
      para2 = String.duplicate("b", 3500)
      text = para1 <> "\n\n" <> para2

      assert [chunk1, chunk2] = Format.chunks(text)
      assert chunk1 == para1
      assert chunk2 == para2
    end

    test "falls back to single-newline split when no paragraph break fits" do
      line1 = String.duplicate("a", 3500)
      line2 = String.duplicate("b", 3500)
      text = line1 <> "\n" <> line2

      assert [chunk1, chunk2] = Format.chunks(text)
      assert chunk1 == line1
      assert chunk2 == line2
    end

    test "hard-splits when a single line exceeds the cap" do
      text = String.duplicate("x", 5000)
      assert [chunk1, chunk2] = Format.chunks(text)
      assert String.length(chunk1) <= 4000
      assert String.length(chunk2) <= 4000
      assert chunk1 <> chunk2 == text
    end

    test "all chunks stay within Telegram's 4096 cap" do
      text = String.duplicate("a paragraph\n\n", 600)
      chunks = Format.chunks(text)
      Enum.each(chunks, fn c -> assert String.length(c) <= 4096 end)
    end
  end
end
