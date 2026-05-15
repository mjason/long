defmodule Long.Agent.Browser.EngineTest do
  use ExUnit.Case, async: false

  alias Long.Agent.Browser.{CDP, Engine}

  defp safe_stop(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 200)
      catch
        :exit, _ -> :ok
      end
    end
  end

  setup do
    original = Application.get_env(:long, Long.Agent.Browser)
    on_exit(fn -> Application.put_env(:long, Long.Agent.Browser, original) end)
    :ok
  end

  describe "Engine boot" do
    test "binary already installed in bin_dir → :ready" do
      bin_dir = Path.join(System.tmp_dir!(), "long_engine_ready_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(bin_dir)
      bin_path = Path.join(bin_dir, "obscura")
      File.write!(bin_path, "#!/bin/sh\necho stub\n")
      File.chmod!(bin_path, 0o755)
      on_exit(fn -> File.rm_rf!(bin_dir) end)

      Application.put_env(:long, Long.Agent.Browser,
        obscura_bin: "obscura",
        obscura_bin_dir: bin_dir,
        auto_install: true
      )

      {:ok, pid} = Engine.start_link(name: :engine_ready_test)
      on_exit(fn -> safe_stop(pid) end)

      assert {:ok, :ready, path} = GenServer.call(pid, :status)
      assert path == Path.expand(bin_path)
    end

    test "binary missing + auto_install false → :failed (no download)" do
      bin_dir = Path.join(System.tmp_dir!(), "long_engine_skip_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(bin_dir)
      on_exit(fn -> File.rm_rf!(bin_dir) end)

      Application.put_env(:long, Long.Agent.Browser,
        obscura_bin: "obscura-zzz-nope",
        obscura_bin_dir: bin_dir,
        auto_install: false
      )

      {:ok, pid} = Engine.start_link(name: :engine_skip_test)
      on_exit(fn -> safe_stop(pid) end)

      assert {:error, :failed} = GenServer.call(pid, :status)
    end

    test "binary missing + auto_install true → :installing while task runs" do
      bin_dir = Path.join(System.tmp_dir!(), "long_engine_inst_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(bin_dir)
      on_exit(fn -> File.rm_rf!(bin_dir) end)

      Application.put_env(:long, Long.Agent.Browser,
        obscura_bin: "obscura-zzz-nope",
        obscura_bin_dir: bin_dir,
        auto_install: true
      )

      blocking_installer = fn _opts ->
        Process.sleep(5_000)
        {:error, :test_aborted}
      end

      {:ok, pid} =
        Engine.start_link(name: :engine_inst_test, installer: blocking_installer)

      on_exit(fn -> safe_stop(pid) end)

      assert {:ok, :installing} = GenServer.call(pid, :status)
    end
  end

  describe "CDP.unreachable_hint/0" do
    test "mentions Obscura + auto-install + http_fetch fallback" do
      assert hint = CDP.unreachable_hint()
      assert hint =~ "Obscura"
      assert hint =~ "downloading"
      assert hint =~ "http_fetch"
    end
  end
end
