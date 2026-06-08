defmodule Long.Jido.Tools.Format do
  @moduledoc """
  Small shared helpers used across jido tool actions: pulling
  `session_id` out of `ctx`, flattening Ash error trees into a single
  human-readable string, and ISO8601 formatting for DateTime fields
  that get returned to the LLM.
  """

  @doc """
  Returns `{:ok, session_id}` when `ctx` carries a non-empty `:session_id`,
  otherwise `{:error, reason}`.
  """
  def require_session_id(ctx) do
    case ctx[:session_id] do
      sid when is_binary(sid) and sid != "" -> {:ok, sid}
      _ -> {:error, "tool requires a session context"}
    end
  end

  @doc """
  The household member id bound to `ctx`'s session, or `nil` for an
  unbound / web-chat session. Centralizes the session→member lookup that
  per-member tools (code_run, skill_read) need to scope themselves.
  """
  def member_id_for_session(ctx) do
    case require_session_id(ctx) do
      {:ok, sid} -> Long.Agent.member_id_for_session(sid)
      _ -> nil
    end
  end

  @doc "ISO8601-encode a DateTime; return nil for non-DateTime input."
  def iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def iso8601(_), do: nil

  @doc """
  Collapse an `Ash.Error.Invalid` into one string. Falls back to
  `inspect/1` so callers can pattern-match a single shape.
  """
  def ash_error_message(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    Enum.map_join(errors, "; ", &Exception.message/1)
  end

  def ash_error_message(e), do: inspect(e)
end
