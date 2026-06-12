defmodule Long.Jido.Tools.SetTimezone do
  @moduledoc """
  Update the user's timezone — the zone used to convert stated local times
  ("tomorrow 8:30am") into the UTC stored on scheduled tasks. Persisted as a
  system setting (`Long.Agent.Setting`), not memory.

  The current time and the user's zone are already injected every turn, so
  this is only needed when the user tells you they're somewhere else.
  """
  use Jido.Action,
    name: "set_timezone",
    description: """
    Set the user's timezone — an IANA name like "Asia/Shanghai",
    "America/New_York", or "Europe/London". Call this ONLY when the user tells
    you where they are or that they've moved. You do NOT need it to read the
    time: the current time and zone are already given to you each turn.
    """,
    category: "settings",
    tags: ["timezone", "settings"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        timezone: Zoi.string(description: "IANA timezone name, e.g. \"Asia/Shanghai\".")
      })

  @impl true
  def run(params, _ctx) do
    tz = params[:timezone]

    case Long.Agent.put_user_timezone(tz) do
      :ok ->
        {:ok, %{status: "ok", timezone: tz}}

      :error ->
        {:ok,
         %{
           status: "error",
           msg: "Unknown timezone: #{inspect(tz)}. Use an IANA name like \"Asia/Shanghai\"."
         }}
    end
  end
end
