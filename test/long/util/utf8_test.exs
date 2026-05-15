defmodule Long.Util.Utf8Test do
  use ExUnit.Case, async: true

  alias Long.Util.Utf8

  describe "safe_truncate/2" do
    test "passes short binaries through unchanged" do
      assert Utf8.safe_truncate("hello", 10) == "hello"
    end

    test "ASCII truncation lands on exact byte boundary" do
      assert Utf8.safe_truncate("hello world", 5) == "hello"
    end

    test "Chinese truncation lands on character boundary, not mid-byte" do
      # Each Chinese character is 3 bytes. "超人力" is 9 bytes.
      # Cutting at 8 bytes would split "力" — must instead cut at 6.
      result = Utf8.safe_truncate("超人力", 8)
      assert byte_size(result) == 6
      assert String.valid?(result)
      assert result == "超人"
    end

    test "result of truncation is always valid UTF-8" do
      bin = "超人力霸王雷歐 - 维基百科"

      for n <- 1..byte_size(bin) do
        out = Utf8.safe_truncate(bin, n)
        assert String.valid?(out), "byte cap #{n} produced invalid UTF-8: #{inspect(out)}"
      end
    end

    test "returns input unchanged when not a binary" do
      assert Utf8.safe_truncate(123, 5) == 123
    end
  end

  describe "head_tail/3" do
    test "passes short input through" do
      assert Utf8.head_tail("abc", 100) == "abc"
    end

    test "produces head + marker + tail and valid UTF-8" do
      bin = String.duplicate("中", 200)
      out = Utf8.head_tail(bin, 60, "\n...\n")

      assert byte_size(out) < byte_size(bin)
      assert String.valid?(out)
      assert String.contains?(out, "...")
    end
  end

  describe "sanitize/1" do
    test "leaves valid UTF-8 alone" do
      assert Utf8.sanitize("超人力") == "超人力"
      assert Utf8.sanitize("hello") == "hello"
    end

    test "replaces invalid byte sequence with U+FFFD" do
      bad = <<0xE7, 0x88, 232>>
      out = Utf8.sanitize(bad)
      assert String.valid?(out)
      assert out =~ "�"
    end

    test "recurses into maps" do
      bad = <<0xE7, 0x88>>
      assert %{a: "x", b: out} = Utf8.sanitize(%{a: "x", b: bad})
      assert String.valid?(out)
    end

    test "recurses into lists" do
      bad = <<0xE7>>
      assert [out, "ok"] = Utf8.sanitize([bad, "ok"])
      assert String.valid?(out)
    end

    test "passes non-binary leaves unchanged" do
      assert Utf8.sanitize(:atom) == :atom
      assert Utf8.sanitize(42) == 42
      assert Utf8.sanitize(nil) == nil
      assert Utf8.sanitize(true) == true
    end
  end
end
