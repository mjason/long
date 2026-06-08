defmodule Long.Agent.Deno.InstallerTest do
  use ExUnit.Case, async: false

  alias Long.Agent.Deno.Installer

  describe "detect_asset/0" do
    test "returns a known Deno release asset for the current platform" do
      assert {:ok, asset} = Installer.detect_asset()

      assert asset in [
               "deno-x86_64-unknown-linux-gnu.zip",
               "deno-aarch64-unknown-linux-gnu.zip",
               "deno-x86_64-apple-darwin.zip",
               "deno-aarch64-apple-darwin.zip",
               "deno-x86_64-pc-windows-msvc.zip"
             ]
    end
  end

  describe "locate/2" do
    test "returns the project-local path when the binary exists there" do
      dir = tmp_dir("deno_locate")
      path = Path.join(dir, "deno")
      File.write!(path, "#!/bin/sh\necho stub\n")
      File.chmod!(path, 0o755)

      assert Installer.locate("deno", dir) == Path.expand(path)
    end

    test "returns nil when the binary is neither on PATH nor in bin_dir" do
      assert Installer.locate("zzz_not_deno_xyz", tmp_dir("deno_empty")) == nil
    end
  end

  describe "ensure_installed/1 with a stubbed download" do
    test "downloads, extracts the zip, and exposes an executable binary" do
      dir = tmp_dir("deno_install")
      zip_bytes = build_zip("deno", "#!/bin/sh\necho 'fake deno 2.x'\n")

      http = fn opts ->
        assert Keyword.fetch!(opts, :url) =~ "deno-"
        {:ok, %Req.Response{status: 200, body: zip_bytes}}
      end

      assert {:ok, path} = Installer.ensure_installed(bin_dir: dir, bin_name: "deno", http: http)
      assert path == Path.expand(Path.join(dir, "deno"))
      assert File.exists?(path)
      assert File.stat!(path).mode |> Bitwise.band(0o100) == 0o100
    end

    test "skips the download when already installed" do
      dir = tmp_dir("deno_cached")
      path = Path.join(dir, "deno")
      File.write!(path, "stub")
      File.chmod!(path, 0o755)

      http = fn _ -> flunk("should not download when already present") end

      assert {:ok, resolved} = Installer.ensure_installed(bin_dir: dir, bin_name: "deno", http: http)
      assert resolved == Path.expand(path)
    end

    test "surfaces a download error instead of crashing" do
      http = fn _ -> {:ok, %Req.Response{status: 503, body: ""}} end

      assert {:error, {:http_status, 503}} =
               Installer.ensure_installed(bin_dir: tmp_dir("deno_fail"), bin_name: "deno", http: http)
    end
  end

  defp tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp build_zip(name, contents) do
    {:ok, {_zipname, bytes}} =
      :zip.create(~c"deno.zip", [{to_charlist(name), contents}], [:memory])

    bytes
  end
end
