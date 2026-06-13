defmodule Long.Agent.Bots.Wechat.MarkdownTest do
  use ExUnit.Case, async: true

  alias Long.Agent.Bots.Wechat.Markdown

  describe "code is protected (mirrors the official filter's fence state)" do
    test "markdown inside a fenced code block is kept verbatim" do
      input = "```python\ns = \"~~x~~\"\n##### not a heading\n*列表*\n> q\n```"
      assert Markdown.strip_markdown(input) == input
    end

    test "inline code is kept verbatim" do
      assert Markdown.strip_markdown("run `rm ~~x~~ *中文*` now") == "run `rm ~~x~~ *中文*` now"
    end

    test "an unclosed trailing fence still protects its content" do
      input = "text\n```\n~~keep~~ *列表*"
      assert Markdown.strip_markdown(input) == input
    end
  end

  describe "plain text outside code is stripped" do
    test "strikethrough markers removed, content kept" do
      assert Markdown.strip_markdown("~~gone~~") == "gone"
    end

    test "italic over CJK stripped; non-CJK italic and bold kept" do
      assert Markdown.strip_markdown("*中文* and *en* and **b**") == "中文 and *en* and **b**"
    end

    test "H5/H6 markers stripped, content kept" do
      assert Markdown.strip_markdown("##### h5\n###### h6") == "h5\nh6"
    end

    test "images removed entirely" do
      assert Markdown.strip_markdown("a ![alt](http://u) b") == "a  b"
    end
  end

  describe "clean/1 drops framing tokens and trims" do
    test "strips <thinking> blocks and the turn header" do
      assert Markdown.clean("LLM Running (Turn 3) ...\n<thinking>secret</thinking>\nhi") == "hi"
    end

    test "a real code block survives clean/1 end-to-end" do
      assert Markdown.clean("```\n~~x~~ *列表*\n```") == "```\n~~x~~ *列表*\n```"
    end
  end
end
