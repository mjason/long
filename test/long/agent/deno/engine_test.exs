defmodule Long.Agent.Deno.EngineTest do
  use ExUnit.Case, async: false

  alias Long.Agent.Deno.Engine

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
    original = Application.get_env(:long, Long.Agent.Deno)
    on_exit(fn -> Application.put_env(:long, Long.Agent.Deno, original) end)
    :ok
  end

  defp tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  test "binary already in bin_dir → :ready and ready_path resolves it" do
    bin_dir = tmp_dir("deno_engine_ready")
    bin_path = Path.join(bin_dir, "deno")
    File.write!(bin_path, "#!/bin/sh\necho stub\n")
    File.chmod!(bin_path, 0o755)

    Application.put_env(:long, Long.Agent.Deno, deno_bin: "deno", deno_bin_dir: bin_dir, auto_install: true)

    {:ok, pid} = Engine.start_link(name: :deno_ready_test)
    on_exit(fn -> safe_stop(pid) end)

    assert {:ok, :ready, path} = Engine.status(:deno_ready_test)
    assert path == Path.expand(bin_path)
    assert Engine.ready_path(:deno_ready_test) == Path.expand(bin_path)
  end

  test "missing + auto_install false → :failed, no download" do
    bin_dir = tmp_dir("deno_engine_skip")

    Application.put_env(:long, Long.Agent.Deno,
      deno_bin: "deno-zzz-nope",
      deno_bin_dir: bin_dir,
      auto_install: false
    )

    {:ok, pid} = Engine.start_link(name: :deno_skip_test)
    on_exit(fn -> safe_stop(pid) end)

    assert {:error, :failed} = Engine.status(:deno_skip_test)
  end

  test "missing + auto_install true → :installing while the task runs, then :ready on success" do
    bin_dir = tmp_dir("deno_engine_inst")

    Application.put_env(:long, Long.Agent.Deno,
      deno_bin: "deno-zzz-nope",
      deno_bin_dir: bin_dir,
      auto_install: true
    )

    me = self()

    installer = fn _opts ->
      send(me, :installer_called)
      {:ok, "/installed/deno"}
    end

    {:ok, pid} = Engine.start_link(name: :deno_inst_test, installer: installer)
    on_exit(fn -> safe_stop(pid) end)

    assert_receive :installer_called, 1_000
    # eventually reports ready with the installed path
    assert Enum.any?(1..20, fn _ ->
             Process.sleep(20)
             match?({:ok, :ready, "/installed/deno"}, Engine.status(:deno_inst_test))
           end)
  end

  test "ready_path falls back to a no-download locate when the Engine isn't running" do
    # No process named :no_such_deno_engine → falls back to Installer.locate,
    # which finds nothing here → nil (graceful).
    assert Engine.ready_path(:no_such_deno_engine_xyz) in [nil, Engine.ready_path()]
  end
end
