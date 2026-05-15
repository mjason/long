defmodule Long.Agent.Browser.InstallerTest do
  use ExUnit.Case, async: false

  alias Long.Agent.Browser.Installer

  describe "detect_asset/0" do
    test "returns a known asset filename for the current platform" do
      assert {:ok, asset} = Installer.detect_asset()

      assert asset in [
               "obscura-x86_64-linux.tar.gz",
               "obscura-aarch64-macos.tar.gz",
               "obscura-x86_64-macos.tar.gz",
               "obscura-x86_64-windows.zip"
             ]
    end
  end

  describe "locate/2" do
    test "returns the project-local path when binary exists there" do
      dir = Path.join(System.tmp_dir!(), "installer_locate_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "obscura")
      File.write!(path, "#!/bin/sh\necho stub\n")
      File.chmod!(path, 0o755)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert Installer.locate("obscura", dir) == Path.expand(path)
    end

    test "returns nil when binary is neither on PATH nor in bin_dir" do
      dir = Path.join(System.tmp_dir!(), "installer_empty_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert Installer.locate("zzz_not_a_binary_xyz", dir) == nil
    end
  end

  describe "ensure_installed/1 with stubbed download" do
    test "downloads, extracts tar.gz, and exposes the binary" do
      dir = Path.join(System.tmp_dir!(), "installer_install_#{:rand.uniform(1_000_000)}")
      on_exit(fn -> File.rm_rf!(dir) end)

      # Build a real tar.gz fixture containing a tiny shell-script
      # "binary" so the extract path runs end-to-end.
      tar_bytes = build_tar_gz("obscura", "#!/bin/sh\necho 'fake obscura'\n")

      http = fn opts ->
        assert Keyword.fetch!(opts, :url) =~ "obscura-"
        {:ok, %Req.Response{status: 200, body: tar_bytes}}
      end

      assert {:ok, path} =
               Installer.ensure_installed(
                 bin_dir: dir,
                 bin_name: "obscura",
                 http: http
               )

      assert path == Path.expand(Path.join(dir, "obscura"))
      assert File.exists?(path)
      assert File.stat!(path).mode |> Bitwise.band(0o100) == 0o100
    end

    test "surfaces download errors instead of crashing" do
      dir = Path.join(System.tmp_dir!(), "installer_fail_#{:rand.uniform(1_000_000)}")
      on_exit(fn -> File.rm_rf!(dir) end)

      http = fn _opts -> {:ok, %Req.Response{status: 503, body: ""}} end

      assert {:error, {:http_status, 503}} =
               Installer.ensure_installed(
                 bin_dir: dir,
                 bin_name: "obscura",
                 http: http
               )
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp build_tar_gz(filename, contents) do
    tmp = Path.join(System.tmp_dir!(), "installer_fixture_#{:rand.uniform(1_000_000)}.tar.gz")
    file_path = to_charlist(filename)

    :ok =
      :erl_tar.create(
        to_charlist(tmp),
        [{file_path, contents}],
        [:compressed]
      )

    bytes = File.read!(tmp)
    File.rm!(tmp)
    bytes
  end
end
