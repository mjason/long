defmodule Long.Util.ErrorTest do
  use ExUnit.Case, async: true

  alias Long.Util.Error

  test "extracts message from exception structs" do
    assert "boom" == Error.humanize(%RuntimeError{message: "boom"})
  end

  test "passes binaries through unchanged" do
    assert "已读" == Error.humanize("已读")
  end

  test "inspects everything else" do
    assert ":weird" == Error.humanize(:weird)
    assert "{:noproc, :unknown}" == Error.humanize({:noproc, :unknown})
  end
end
