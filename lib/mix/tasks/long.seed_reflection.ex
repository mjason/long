defmodule Mix.Tasks.Long.SeedReflection do
  @moduledoc """
  Backfill a daily silent-reflection task for existing sessions.

  Silent reflection is the autonomous "tidy your own memory" loop: a
  `Long.Agent.ScheduledTask` with `silent: true` that, off-peak, has the
  agent consolidate a session's own memory without messaging anyone (see
  `Long.Agent.Server` / `Long.Agent.Workers.RunScheduledTask`).

  New sessions can be seeded at bind time; this task covers installs that
  already have sessions. It is idempotent (one reflection task per session,
  by the globally-unique name `reflection:<session_id>`) and safe to re-run.
  Archived sessions and unbound-stranger sessions are skipped.

      mix long.seed_reflection
  """
  use Mix.Task

  @shortdoc "Seed daily silent-reflection tasks for existing sessions"

  alias Long.Agent

  @impl true
  def run(_argv) do
    Mix.Task.run("app.start")

    {:ok, sessions} = Agent.list_sessions()

    active = Enum.reject(sessions, &(&1.status == :archived))

    {created, existing, skipped, errors} =
      Enum.reduce(active, {0, 0, 0, 0}, fn session, {c, e, s, err} ->
        case Agent.ensure_reflection_task(session.id) do
          {:ok, :skipped} -> {c, e, s + 1, err}
          {:ok, %{inserted_at: nil}} -> {c + 1, e, s, err}
          {:ok, task} -> tally_existing_or_created(task, {c, e, s, err})
          {:error, _} -> {c, e, s, err + 1}
        end
      end)

    Mix.shell().info(
      "Reflection seeding done over #{length(active)} active session(s): " <>
        "#{created} created, #{existing} already had one, " <>
        "#{skipped} skipped (no member), #{errors} error(s)."
    )
  end

  # `ensure_reflection_task` returns the row whether it created or found it;
  # `inserted_at == updated_at` is the cheap "freshly created" signal.
  defp tally_existing_or_created(task, {c, e, s, err}) do
    if task.inserted_at == task.updated_at do
      {c + 1, e, s, err}
    else
      {c, e + 1, s, err}
    end
  end
end
