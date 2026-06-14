defmodule Long.Jido.Tools.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Long.Jido.Tools.Workspace

  @root "/tmp/long_ws_test_root"

  defp ctx, do: %{workspace_root: @root}

  describe "resolve_path/2" do
    test "a relative path resolves under the workspace root" do
      assert {:ok, "#{@root}/sub/file.txt"} == Workspace.resolve_path(ctx(), "sub/file.txt")
    end

    # Regression: the inbound-file marker we hand the model is absolute
    # (`<workspace_root>/wechat_inbox/…`). Path.join used to nest it under
    # base → wrong path → File.read enoent → the model said "no permission".
    test "an absolute path inside the root is honored as-is, not nested under base" do
      abs = "#{@root}/wechat_inbox/一年级语文上册期末复习计划.doc"
      assert {:ok, ^abs} = Workspace.resolve_path(ctx(), abs)
    end

    test "a web_inbox absolute path also resolves" do
      abs = "#{@root}/web_inbox/some-session-id/report.pdf"
      assert {:ok, ^abs} = Workspace.resolve_path(ctx(), abs)
    end

    test "the workspace root itself resolves" do
      assert {:ok, @root} = Workspace.resolve_path(ctx(), ".")
    end

    test "an absolute path outside the root is rejected (no system-file reads)" do
      assert {:error, _} = Workspace.resolve_path(ctx(), "/etc/passwd")
    end

    test "a ../ escape is rejected" do
      assert {:error, _} = Workspace.resolve_path(ctx(), "../../etc/passwd")
    end

    test "nil / empty path errors" do
      assert {:error, _} = Workspace.resolve_path(ctx(), nil)
      assert {:error, _} = Workspace.resolve_path(ctx(), "")
    end
  end
end
