defmodule Long.Jido.Tools.FileReadTest do
  use ExUnit.Case, async: true

  alias Long.Jido.Tools.FileRead

  setup do
    root = Path.join(System.tmp_dir!(), "fr_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, ctx: %{workspace_root: root}}
  end

  test "reads a text file via a relative path", %{root: root, ctx: ctx} do
    File.write!(Path.join(root, "a.txt"), "line1\nline2\n")
    assert {:ok, %{status: "success", content: c}} = FileRead.run(%{path: "a.txt"}, ctx)
    assert c =~ "line1"
  end

  # Regression: the inbound-file marker is an absolute path inside the
  # workspace. It must resolve (previously Path.join mangled it → enoent →
  # the model said "no permission").
  test "reads via an absolute path inside the workspace (the inbound-file case)", %{root: root, ctx: ctx} do
    abs = Path.join(root, "inbox/doc.txt")
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, "hello from inbox")
    assert {:ok, %{status: "success", content: c}} = FileRead.run(%{path: abs}, ctx)
    assert c =~ "hello from inbox"
  end

  # A binary blob (.docx zip / .pdf / .doc) must steer the model to code_run
  # instead of returning mojibake — the file now lives in the member inbox
  # that code_run can open.
  test "a binary file returns a code_run hint, not mojibake", %{root: root, ctx: ctx} do
    File.write!(Path.join(root, "doc.docx"), <<0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0>>)
    assert {:ok, %{status: "error", msg: msg}} = FileRead.run(%{path: "doc.docx"}, ctx)
    assert msg =~ "code_run"
    assert msg =~ "binary"
  end

  test "rejects a path escaping the workspace root", %{ctx: ctx} do
    assert {:ok, %{status: "error", msg: msg}} = FileRead.run(%{path: "/etc/passwd"}, ctx)
    assert msg =~ "workspace" or msg =~ "escape"
  end
end
