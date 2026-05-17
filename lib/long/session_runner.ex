defmodule Long.SessionRunner do
  @moduledoc """
  Thin dispatcher that picks between the legacy
  `Long.Agent.SessionRunner` and the new `Long.Jido.SessionRunner` based
  on application config. LiveView / Bot / CLI call this module instead of
  one specific implementation so we can flip the agent runtime via config.

  Configure with:

      config :long, :session_runner, Long.Agent.SessionRunner   # or Long.Jido.SessionRunner

  Default: `Long.Jido.SessionRunner` — backed by `Long.Agent.Server`
  (GenServer), so `Long.Agent.SessionClear.clear/1` can actually
  terminate an in-flight turn. The legacy fire-and-forget Task runner
  pre-dated `terminate_session/1`; using it in prod left `/clear`
  unable to stop a running Loop, which kept persisting messages after
  the wipe.
  """

  def topic(session_id), do: impl().topic(session_id)
  def subscribe(session_id), do: impl().subscribe(session_id)
  def unsubscribe(session_id), do: impl().unsubscribe(session_id)

  def send_user_message(session_id, text, opts \\ []),
    do: impl().send_user_message(session_id, text, opts)

  @doc """
  Translate the reason payload broadcast on `{:done, reason}` into a
  user-facing notice, or `nil` for reasons that don't warrant one.
  Both runners broadcast the same shape, so the mapping lives here
  rather than per-implementation.
  """
  def done_notice(%{reason: :max_turns}) do
    %{
      kind: :warning,
      text:
        "Agent stopped after hitting the max-turn limit. The task wasn't finished — " <>
          "send a follow-up like \"continue\" to resume."
    }
  end

  def done_notice(%{reason: :error, error: e}),
    do: %{kind: :error, text: "Agent error: " <> Exception.message(e)}

  def done_notice(_), do: nil

  defp impl,
    do: Application.get_env(:long, :session_runner, Long.Jido.SessionRunner)
end
