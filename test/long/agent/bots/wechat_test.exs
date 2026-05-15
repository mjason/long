defmodule Long.Agent.Bots.WechatTest do
  use Long.DataCase, async: false

  alias Long.Agent.Bots.Wechat.{Client, Credential, Crypto, Markdown}

  describe "Crypto" do
    test "encrypt/decrypt round-trips with PKCS7 padding" do
      key = :crypto.strong_rand_bytes(16)
      plaintext = "hello world this is a test payload for AES ECB"

      assert plaintext == plaintext |> Crypto.encrypt(key) |> Crypto.decrypt(key)
    end

    test "encrypt pads to full block when input is block-aligned" do
      key = :crypto.strong_rand_bytes(16)
      aligned = String.duplicate("A", 16)

      # 16-byte input still gets a full 16-byte pad block per PKCS7
      assert byte_size(Crypto.encrypt(aligned, key)) == 32
    end

    test "ciphertext_size matches Python's `((n // 16) + 1) * 16`" do
      assert Crypto.ciphertext_size(0) == 16
      assert Crypto.ciphertext_size(1) == 16
      assert Crypto.ciphertext_size(15) == 16
      assert Crypto.ciphertext_size(16) == 32
      assert Crypto.ciphertext_size(17) == 32
      assert Crypto.ciphertext_size(31) == 32
    end
  end

  describe "Credential" do
    test "load returns nil when no row exists" do
      assert Credential.load() == nil
      refute Credential.has_token?()
    end

    test "save then load round-trips" do
      assert {:ok, _} =
               Credential.save(%{bot_token: "abc", ilink_bot_id: "bot-123", updates_buf: "buf"})

      assert %{bot_token: "abc", ilink_bot_id: "bot-123", updates_buf: "buf"} = Credential.load()
      assert Credential.has_token?()
    end

    test "save_buf preserves bot_token and ilink_bot_id" do
      {:ok, _} = Credential.save(%{bot_token: "abc", ilink_bot_id: "bot-123", updates_buf: ""})
      :ok = Credential.save_buf("newcursor")

      assert %{bot_token: "abc", ilink_bot_id: "bot-123", updates_buf: "newcursor"} =
               Credential.load()
    end

    test "save_buf is a no-op when no row exists" do
      assert :ok = Credential.save_buf("anything")
      assert Credential.load() == nil
    end

    test "named credentials are independent" do
      {:ok, _} = Credential.save(%{bot_token: "a", ilink_bot_id: "x", updates_buf: ""}, "alpha")
      {:ok, _} = Credential.save(%{bot_token: "b", ilink_bot_id: "y", updates_buf: ""}, "beta")

      assert %{bot_token: "a"} = Credential.load("alpha")
      assert %{bot_token: "b"} = Credential.load("beta")
    end
  end

  describe "Client.extract_text" do
    test "concatenates text from text_item parts" do
      msg = %{
        "item_list" => [
          %{"type" => Client.item_text(), "text_item" => %{"text" => "hello"}},
          %{"type" => Client.item_text(), "text_item" => %{"text" => "world"}},
          %{"type" => Client.item_image(), "image_item" => %{}}
        ]
      }

      assert Client.extract_text(msg) == "hello\nworld"
    end

    test "returns empty string for non-text messages" do
      assert Client.extract_text(%{"item_list" => []}) == ""
      assert Client.extract_text(%{}) == ""
    end
  end

  describe "Client.user_msg?" do
    test "true for message_type=MSG_USER" do
      assert Client.user_msg?(%{"message_type" => Client.msg_user()})
    end

    test "false for bot echoes" do
      refute Client.user_msg?(%{"message_type" => Client.msg_bot()})
      refute Client.user_msg?(%{})
    end
  end

  describe "Markdown.clean" do
    test "strips Turn-N headers and tool-call echoes" do
      input = """
      LLM Running (Turn 1) ...
      🛠️ http_fetch(url="https://x")
      Actual content here.
      """

      out = Markdown.clean(input)
      refute out =~ "Turn 1"
      refute out =~ "🛠️"
      assert out =~ "Actual content"
    end

    test "removes hidden thinking and tool_use tags" do
      input = "<thinking>plotting</thinking>visible<tool_use>x</tool_use>"
      assert Markdown.clean(input) == "visible"
    end

    test "keeps markdown links as-is (WeChat renders them)" do
      input = "Visit [docs](https://example.com) for more"
      assert Markdown.clean(input) == input
    end

    test "removes inline image syntax entirely" do
      assert Markdown.clean("before ![alt](http://x.png) after") =~ "before"
      refute Markdown.clean("![](http://x.png)") =~ "x.png"
    end

    test "keeps code fences and inline code" do
      input = "```python\nprint('hi')\n```\nand `inline` too"
      out = Markdown.clean(input)
      assert out =~ "```python"
      assert out =~ "print('hi')"
      assert out =~ "`inline`"
    end

    test "keeps list markers as-is (WeChat renders ordered and unordered lists)" do
      input = "- one\n- two\n\n1. first\n2. second"
      out = Markdown.clean(input)
      assert out =~ "- one"
      assert out =~ "- two"
      assert out =~ "1. first"
      assert out =~ "2. second"
    end

    test "keeps H1-H4 markers, strips H5/H6" do
      assert Markdown.clean("# top\n## sub\n### sub2\n#### sub3") =~ "# top"
      assert Markdown.clean("##### deep\nbody") =~ "deep\nbody"
      refute Markdown.clean("##### deep") =~ "#####"
    end

    test "strips strikethrough markers but keeps content" do
      assert Markdown.clean("foo ~~bar~~ baz") == "foo bar baz"
    end

    test "strips italic markers around CJK content" do
      assert Markdown.clean("这是 *中文* 测试") == "这是 中文 测试"
      assert Markdown.clean("这是 _中文_ 测试") == "这是 中文 测试"
    end

    test "keeps italic markers around non-CJK content" do
      assert Markdown.clean("this is *latin* text") == "this is *latin* text"
      assert Markdown.clean("this is _latin_ text") == "this is _latin_ text"
    end

    test "leaves bold alone even when adjacent to CJK italic patterns" do
      assert Markdown.clean("**重点** 是 *斜体*") == "**重点** 是 斜体"
    end

    test "strips bold-italic markers around CJK content" do
      assert Markdown.clean("***中文***") == "中文"
      assert Markdown.clean("___中文___") == "中文"
    end

    test "horizontal rules survive" do
      input = "---\nseparator\n---"
      out = Markdown.clean(input)
      assert out =~ "---"
    end
  end
end
