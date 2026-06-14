defmodule Long.Agent.CodeRunnerTest do
  use Long.DataCase, async: false

  alias Long.Agent
  alias Long.Agent.CodeRunner
  alias Long.Agent.DenoEnv
  alias Long.Jido.Tools.CodeRun

  describe "normalize_type/1 — Deno + bash only, no Python" do
    test "JS/TS aliases map to deno" do
      for t <- ~w(js ts javascript typescript), do: assert(CodeRunner.normalize_type(t) == "deno")
    end

    test "shell aliases map to bash" do
      assert CodeRunner.normalize_type("shell") == "bash"
      assert CodeRunner.normalize_type("sh") == "bash"
    end

    test "python is NOT a recognized alias (passes through as-is)" do
      assert CodeRunner.normalize_type("python") == "python"
      assert CodeRunner.normalize_type("py") == "py"
    end
  end

  describe "build_command/3" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cr_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "python is unsupported", %{dir: dir} do
      assert {:error, "unsupported code_type: python"} = CodeRunner.build_command("x=1", "python", dir)
    end

    test "bash builds an inline command", %{dir: dir} do
      assert {:ok, "bash", ["-c", "echo hi"], _cleanup} = CodeRunner.build_command("echo hi", "bash", dir)
    end

    test "bash rejects every language runtime (no interpreter back door)", %{dir: dir} do
      for code <- [
            "python3 read_hackernews.py",
            "python script.py",
            "pip install requests",
            "/usr/bin/python3 x.py",
            "cat data.json | python3 parse.py",
            "cd sub && python3 run.py",
            "env python3 run.py",
            "node read_hackernews_latest.js",
            "node --experimental-fetch x.js",
            "npx tsx run.ts",
            "bun run script.ts",
            "ruby fetch.rb",
            "perl -e 'print 1'",
            "deno run --allow-all evil.ts"
          ] do
        assert {:error, msg} = CodeRunner.build_command(code, "bash", dir), "expected #{code} blocked"
        assert msg =~ "Deno-only"
      end
    end

    test "bash still allows system CLIs and commands that merely mention a runtime", %{dir: dir} do
      assert {:ok, "bash", _, _} = CodeRunner.build_command("ls node_modules", "bash", dir)
      assert {:ok, "bash", _, _} = CodeRunner.build_command("cat read_hackernews.py", "bash", dir)
      assert {:ok, "bash", _, _} = CodeRunner.build_command("date '+%Y-%m-%d'", "bash", dir)
      assert {:ok, "bash", _, _} = CodeRunner.build_command("git status && ls -la", "bash", dir)
    end

    test "build_deno_file runs a file with workspace-scoped sandbox flags", %{dir: dir} do
      file = Path.join(dir, "run.ts")

      case DenoEnv.deno_bin() do
        {:ok, _} ->
          assert {:ok, _deno, args, _cleanup} = CodeRunner.build_deno_file(file, dir)
          assert "run" in args
          assert "--allow-read=#{dir}" in args
          assert "--allow-write=#{dir}" in args
          assert file in args

        {:error, _} ->
          assert {:error, msg} = CodeRunner.build_deno_file(file, dir)
          assert msg =~ "deno not available"
      end
    end
  end

  describe "DenoEnv.confine/2 — sandbox boundary" do
    test "keeps a normal relative cwd inside the workspace" do
      ws = "/tmp/members/alice"
      assert DenoEnv.confine(ws, "project") == "/tmp/members/alice/project"
      assert DenoEnv.confine(ws, nil) == ws
      assert DenoEnv.confine(ws, "./") == ws
    end

    test "clamps `..` traversal back to the workspace root" do
      ws = "/tmp/members/alice"
      assert DenoEnv.confine(ws, "../bob") == ws
      assert DenoEnv.confine(ws, "../../../etc") == ws
      # an absolute-looking arg is treated relative, never escapes
      assert DenoEnv.confine(ws, "/etc/passwd") == "/tmp/members/alice/etc/passwd"
    end
  end

  describe "code_run tool" do
    setup do
      base = Path.join(System.tmp_dir!(), "crws_#{:rand.uniform(1_000_000)}")
      on_exit(fn -> File.rm_rf!(base) end)
      {:ok, base: base}
    end

    test "bash runs in the shared workspace for an unbound session", %{base: base} do
      ctx = %{session_id: nil, workspace_root: base, max_output_bytes: 10_000}
      assert {:ok, %{status: "success", stdout: out}} = CodeRun.run(%{code: "echo deno-only", type: "bash"}, ctx)
      assert out =~ "deno-only"
    end

    test "each member gets an isolated members/<id> workspace", %{base: base} do
      {:ok, hh} = Agent.create_group(%{name: "H"})
      {:ok, m} = Agent.create_member(%{group_id: hh.id, display_name: "Me", relation: :self})
      sess = Agent.start_session!(%{title: "t"})

      {:ok, _} =
        Agent.create_bot_user(%{platform: :telegram, external_id: "u-#{:rand.uniform(99999)}", session_id: sess.id, member_id: m.id})

      ctx = %{session_id: sess.id, workspace_root: base, max_output_bytes: 10_000}
      assert {:ok, %{status: "success", stdout: out}} = CodeRun.run(%{code: "pwd", type: "bash"}, ctx)
      assert String.contains?(out, Path.join("members", m.id))
    end

    test "unbound/web sessions each get an isolated unbound/<session_id> dir", %{base: base} do
      s1 = Agent.start_session!(%{title: "u1"})
      s2 = Agent.start_session!(%{title: "u2"})
      ctx1 = %{session_id: s1.id, workspace_root: base, max_output_bytes: 10_000}
      ctx2 = %{session_id: s2.id, workspace_root: base, max_output_bytes: 10_000}

      assert {:ok, %{stdout: o1}} = CodeRun.run(%{code: "pwd", type: "bash"}, ctx1)
      assert {:ok, %{stdout: o2}} = CodeRun.run(%{code: "pwd", type: "bash"}, ctx2)

      assert String.contains?(o1, Path.join("unbound", s1.id))
      assert String.contains?(o2, Path.join("unbound", s2.id))
      refute String.trim(o1) == String.trim(o2)
    end

    test "python type is rejected (no Python backend)", %{base: base} do
      ctx = %{session_id: nil, workspace_root: base, max_output_bytes: 10_000}
      assert {:ok, %{status: "error", msg: msg}} = CodeRun.run(%{code: "print(1)", type: "python"}, ctx)
      assert msg =~ "unsupported code_type: python"
    end

    test "shelling out to node via bash is refused", %{base: base} do
      ctx = %{session_id: nil, workspace_root: base, max_output_bytes: 10_000}

      assert {:ok, %{status: "error", msg: msg}} =
               CodeRun.run(%{code: "node read_hackernews_latest.js", type: "bash"}, ctx)

      assert msg =~ "Deno-only"
    end

    test "path: to a missing or escaping file is rejected, never leaving the workspace", %{base: base} do
      ctx = %{session_id: nil, workspace_root: base, max_output_bytes: 10_000}

      assert {:ok, %{status: "error", msg: m1}} = CodeRun.run(%{path: "nope.ts", type: "deno"}, ctx)
      assert m1 =~ "no such file"

      # `..` traversal is confined back into the workspace, so it resolves to a
      # path that doesn't exist there rather than escaping to the host.
      assert {:ok, %{status: "error", msg: m2}} =
               CodeRun.run(%{path: "../../../etc/passwd", type: "deno"}, ctx)

      assert m2 =~ "no such file"
    end
  end

  describe "port_env/1" do
    # Without a writable DENO_DIR the release (running as `nobody`, HOME
    # /nonexistent) can't cache remote modules, so every `import` fails EACCES
    # and code_run can't pull a library (mammoth/.docx, unpdf/PDF, std, …).
    test "sets a writable DENO_DIR so remote imports can cache" do
      env = CodeRunner.port_env("/some/workspace")
      assert {_, dir} = List.keyfind(env, ~c"DENO_DIR", 0)
      assert to_string(dir) =~ ".deno_cache"
    end

    test "prepends the workspace to PATH" do
      env = CodeRunner.port_env("/some/workspace")
      assert {_, path} = List.keyfind(env, ~c"PATH", 0)
      assert to_string(path) =~ "/some/workspace"
    end

    # Blanket --allow-env (see below) would expose container secrets to
    # sandboxed code; port_env unsets them ({name, false}) for the deno child.
    test "blanks out SECRET_KEY_BASE so blanket --allow-env can't leak it" do
      env = CodeRunner.port_env("/some/workspace")
      assert {~c"SECRET_KEY_BASE", false} in env
    end
  end

  describe "deno sandbox env" do
    # A per-library env whitelist proved brittle (each polyfilled dep —
    # readable-stream, bluebird, … — wants a different debug-probe var), so we
    # grant blanket --allow-env and redact secrets in port_env instead.
    test "build_command grants --allow-env (secrets redacted via port_env)" do
      case CodeRunner.build_command("console.log(1)", "deno", System.tmp_dir!()) do
        {:ok, _exe, args, cleanup} ->
          cleanup.()
          assert "--allow-env" in args

        {:error, _} ->
          # deno not installed in this environment — nothing to assert.
          :ok
      end
    end
  end

  describe "kill_port/1" do
    # Regression: it runs on the timeout / output-flood cleanup path and must
    # never raise. `kill` can be absent (slim images), where a bare
    # System.cmd("kill", ...) raised :enoent and crashed the whole code_run.
    test "is best-effort: returns :ok and never raises, even on an exited/closed port" do
      exe = System.find_executable("true") || "/bin/true"
      port = Port.open({:spawn_executable, exe}, [:exit_status, :binary, :hide])

      assert CodeRunner.kill_port(port) == :ok
      # a second call on the now-closed port must also not raise
      assert CodeRunner.kill_port(port) == :ok
    end
  end
end
