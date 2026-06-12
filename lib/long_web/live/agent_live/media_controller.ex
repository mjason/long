defmodule LongWeb.AgentLive.MediaController do
  @moduledoc """
  Serves a web `/chat` session's uploaded attachments back to the browser.

  Files live under the workspace root (`web_inbox/<session_id>/<name>`) so
  the agent's file tools can read them; they are not in `Plug.Static`'s
  allow-list, so this controller is the only way the browser reaches them.
  Both the session id (must be a UUID) and the filename (must be a single
  path segment) are validated to prevent path traversal out of the inbox.
  """
  use LongWeb, :controller

  alias Long.Agent

  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  def show(conn, %{"session_id" => session_id, "name" => name}) do
    with true <- Regex.match?(@uuid, session_id),
         true <- safe_name?(name),
         path = Path.join(Agent.web_inbox_dir(session_id), name),
         true <- File.regular?(path) do
      send_download(conn, {:file, path}, filename: name, disposition: :inline)
    else
      _ -> conn |> put_status(:not_found) |> text("not found")
    end
  end

  # A legitimate upload name is a single path segment — reject anything that
  # could climb out of the inbox dir.
  defp safe_name?(name),
    do: is_binary(name) and name == Path.basename(name) and not String.contains?(name, "..")
end
