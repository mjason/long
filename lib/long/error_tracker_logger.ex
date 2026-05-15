defmodule Long.ErrorTrackerLogger do
  @moduledoc """
  `:logger` handler that forwards any log event carrying a
  `crash_reason` to `ErrorTracker.report/3`.

  Backstop for crashes that bypass `ErrorTracker`'s Phoenix / Oban
  telemetry integrations — e.g. `Phoenix.Socket` serializer errors,
  Bandit transport-level exits, raw `GenServer terminating` reports
  from processes outside the agent/web flow.
  """

  @doc "Install via `:logger.add_handler/3`. Call once at app boot."
  def install do
    # `filter_default: :stop` is scoped to *this* handler — it does not
    # affect the default console handler, so normal `Logger.error("…")`
    # still prints. We only want this handler to fire for crash reports.
    config = %{
      level: :error,
      config: %{},
      filter_default: :stop,
      filters: [
        crash_filter: {&__MODULE__.crash_filter/2, []}
      ]
    }

    case :logger.add_handler(__MODULE__, __MODULE__, config) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
      err -> err
    end
  end

  @doc false
  def log(_log_event, _config), do: :ok

  # `ErrorTracker.report/3` runs `Exception.normalize/3` on its first
  # argument, so we can hand the raw `crash_reason` term straight
  # through — no manual wrapping needed.
  @doc false
  def crash_filter(%{meta: %{crash_reason: {reason, stacktrace}}} = event, _opts)
      when is_list(stacktrace) do
    _ =
      ErrorTracker.report(reason, stacktrace, %{
        source: "logger.crash_reason",
        level: event[:level]
      })

    :stop
  end

  def crash_filter(_event, _opts), do: :ignore
end
