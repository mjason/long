defmodule Long.SessionRunner do
  @moduledoc """
  Thin dispatcher that picks between the legacy
  `Long.Agent.SessionRunner` and the new `Long.Jido.SessionRunner` based
  on application config. LiveView / Bot / CLI call this module instead of
  one specific implementation so we can flip the agent runtime via config.

  Configure with:

      config :long, :session_runner, Long.Jido.SessionRunner   # or Long.Agent.SessionRunner

  Default: `Long.Agent.SessionRunner` (legacy), so existing tests stay
  green without test.exs changes.
  """

  def topic(session_id), do: impl().topic(session_id)
  def subscribe(session_id), do: impl().subscribe(session_id)
  def unsubscribe(session_id), do: impl().unsubscribe(session_id)

  def send_user_message(session_id, text, opts \\ []),
    do: impl().send_user_message(session_id, text, opts)

  defp impl,
    do: Application.get_env(:long, :session_runner, Long.Agent.SessionRunner)
end
