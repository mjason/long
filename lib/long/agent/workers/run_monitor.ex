defmodule Long.Agent.Workers.RunMonitor do
  @moduledoc """
  Runs one `Long.Agent.Monitor` tick: execute its script in the Deno sandbox (no
  LLM), read the decision from the **last stdout JSON line**, and push to the
  member's bot ONLY when it says to — with cooldown + digest dedup so it never
  spams the same alert.

  Decision contract (the script prints exactly this as its last stdout line):

      {"notify": true, "message": "…", "key": "optional-dedup-bucket"}

  A non-zero exit, a timeout, or unparseable output → `last_status: "error"`,
  logged, **no push, no Oban replay** (a bad tick self-heals next interval).
  """

  use Oban.Worker, queue: :agent, max_attempts: 3, unique: [period: 120, fields: [:args]]

  require Logger

  alias Long.Agent
  alias Long.Agent.{CodeRunner, DenoEnv}
  alias Long.Agent.Bots.Outbound

  # Monitors are quick checks, not agent turns. Generous but bounded.
  @timeout_ms 60_000
  @max_output_bytes 16_000
  @stdout_tail 800
  # How many notable runs to keep in history per monitor (older are pruned).
  @keep_runs 100

  @impl true
  def perform(%Oban.Job{args: %{"monitor_id" => id}}) do
    case Agent.get_monitor(id) do
      {:ok, %{enabled: true} = monitor} -> run(monitor)
      {:ok, _disabled} -> :ok
      _ -> :ok
    end
  end

  defp run(monitor) do
    member_id = member_id_for(monitor.session_id)
    base = DenoEnv.session_workspace(nil, member_id, monitor.session_id)
    {:ok, cwd} = DenoEnv.ensure!(base)

    case CodeRunner.build_command(monitor.script || "", "deno", cwd) do
      {:ok, exe, args, cleanup} ->
        outcome = run_script(exe, args, cwd, env(monitor, cwd))
        cleanup.()
        decide(monitor, outcome)

      {:error, reason} ->
        record(monitor, "error", %{"decision" => "build_failed", "reason" => to_string(reason)}, "")
    end
  rescue
    e ->
      Logger.error("RunMonitor: crash on #{monitor.name}: #{inspect(e)}")
      record(monitor, "error", %{"decision" => "crash", "reason" => inspect(e)}, "")
  end

  # ── execution ────────────────────────────────────────────────────────

  # Optionally expose one secret to the script as the SECRET env var.
  defp env(%{secret_name: name}, cwd) when is_binary(name) and name != "" do
    case Agent.get_secret_by_name(name) do
      {:ok, %{value: value}} when is_binary(value) ->
        [{~c"SECRET", String.to_charlist(value)} | CodeRunner.port_env(cwd)]

      _ ->
        CodeRunner.port_env(cwd)
    end
  end

  defp env(_monitor, cwd), do: CodeRunner.port_env(cwd)

  defp run_script(exe, args, cwd, env) do
    CodeRunner.run_and_collect(exe, args, cwd, env, @timeout_ms, @max_output_bytes)
  end

  # ── decision + push ──────────────────────────────────────────────────

  defp decide(monitor, {0, stdout}) do
    case parse_decision(stdout) do
      {:ok, %{notify: true, message: msg}} when is_binary(msg) and msg != "" ->
        maybe_notify(monitor, msg, stdout)

      {:ok, %{notify: true}} ->
        record(monitor, "error", %{"decision" => "notify_without_message"}, stdout)

      {:ok, _} ->
        record(monitor, "silent", %{"decision" => "no_notify"}, stdout)

      {:error, why} ->
        record(monitor, "error", %{"decision" => "unparseable", "why" => inspect(why)}, stdout)
    end
  end

  defp decide(monitor, {status, stdout}) do
    record(monitor, "error", %{"decision" => "exit_#{inspect(status)}"}, stdout)
  end

  # The decision is the LAST non-empty stdout line that parses to a JSON object
  # with a boolean "notify". (Scripts may print debug lines before it.)
  defp parse_decision(stdout) do
    stdout
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value({:error, :no_decision}, fn line ->
      case Jason.decode(line) do
        {:ok, %{"notify" => n} = d} ->
          {:ok, %{notify: n == true, message: d["message"], key: d["key"]}}

        _ ->
          nil
      end
    end)
  end

  defp maybe_notify(monitor, msg, stdout) do
    digest = :crypto.hash(:sha256, msg) |> Base.encode16(case: :lower)

    cond do
      cooling_down?(monitor) ->
        record(monitor, "silent", %{"decision" => "suppressed_cooldown", "message" => msg}, stdout)

      monitor.cooldown_minutes > 0 and digest == monitor.last_digest ->
        record(monitor, "silent", %{"decision" => "suppressed_unchanged", "message" => msg}, stdout)

      true ->
        push = notify(monitor, msg)

        record(
          monitor,
          status_for(push),
          %{"decision" => "notified", "message" => msg, "push" => inspect(push)},
          stdout,
          last_notified_at: now(),
          last_digest: digest
        )
    end
  end

  defp status_for(:ok), do: "notified"
  defp status_for(_), do: "error"

  defp notify(monitor, msg) do
    case Agent.get_bot_user_for_session(monitor.session_id) do
      {:ok, bot_user} -> Outbound.push(bot_user, %{text: msg, ask: nil, attachments: []})
      _ -> {:error, :no_bot_user}
    end
  end

  defp cooling_down?(%{cooldown_minutes: cm, last_notified_at: %DateTime{} = at}) when is_integer(cm) and cm > 0 do
    DateTime.diff(DateTime.utc_now(), at, :second) < cm * 60
  end

  defp cooling_down?(_), do: false

  # ── persistence ──────────────────────────────────────────────────────

  defp record(monitor, status, output, stdout, extra \\ []) do
    tail = tail(stdout)

    attrs =
      extra
      |> Map.new()
      |> Map.merge(%{
        last_run_at: now(),
        last_status: status,
        last_output: Map.put(output, "stdout_tail", tail)
      })

    case Agent.record_monitor_run(monitor, attrs) do
      {:ok, _} -> :ok
      err -> Logger.warning("RunMonitor: record_run failed for #{monitor.name}: #{inspect(err)}")
    end

    decision = Map.get(output, "decision")

    # History: keep NOTABLE runs (an alert, a suppressed alert, an error) — never
    # the silent "no_notify" heartbeat. `last_*` above already shows the latest
    # tick; recording every "nothing happened" would just be noise.
    if decision != "no_notify", do: log_run(monitor, status, decision, output, tail)

    if status == "error" do
      Logger.warning("RunMonitor: #{monitor.name} → error: #{inspect(output)}")
      report_error(monitor, decision, output)
    end

    :ok
  end

  defp log_run(monitor, status, decision, output, tail) do
    attrs = %{
      monitor_id: monitor.id,
      status: status,
      decision: decision,
      message: Map.get(output, "message"),
      stdout_tail: tail,
      ran_at: now()
    }

    case Agent.create_monitor_run_record(attrs) do
      {:ok, _} -> prune_runs(monitor.id)
      err -> Logger.warning("RunMonitor: failed to log run for #{monitor.name}: #{inspect(err)}")
    end
  end

  defp prune_runs(monitor_id) do
    require Ash.Query

    query =
      Long.Agent.MonitorRun
      |> Ash.Query.filter(monitor_id == ^monitor_id)
      |> Ash.Query.sort(inserted_at: :desc)

    case Ash.read(query, page: false, authorize?: false) do
      {:ok, runs} when length(runs) > @keep_runs ->
        runs |> Enum.drop(@keep_runs) |> Enum.each(&Ash.destroy(&1, authorize?: false))

      _ ->
        :ok
    end
  end

  defp report_error(monitor, decision, output) do
    ErrorTracker.report(
      %RuntimeError{message: "monitor run #{decision}: #{monitor.name}"},
      [],
      %{source: "run_monitor", monitor: monitor.name, monitor_id: monitor.id, output: inspect(output)}
    )

    :ok
  rescue
    _ -> :ok
  end

  defp tail(nil), do: ""
  defp tail(s) when byte_size(s) <= @stdout_tail, do: s
  defp tail(s), do: binary_part(s, byte_size(s) - @stdout_tail, @stdout_tail)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp member_id_for(session_id), do: Agent.member_id_for_session(session_id)
end
