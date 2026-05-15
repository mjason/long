defmodule Long.Jido.Tools.SendMedia do
  @moduledoc """
  Queue an image / video / file to be sent back to the platform that
  originated the session (e.g. WeChat). Broadcasts a
  `{:bot_send_media, payload}` event on the session's PubSub topic;
  the bot adapter listening on that topic dispatches the actual upload
  + send when the agent loop ends.

  When called from a chat LiveView session (no bot listening), the
  broadcast is a no-op — the LLM thinks it sent media but nothing
  reaches the user. Today that's a v1 limitation; future versions can
  surface inline media in the chat UI.
  """

  use Jido.Action,
    name: "send_media",
    description: """
    Queue a local file to be sent to the user via the current chat
    platform. `kind` controls how the recipient renders it:

      - "image": jpg/png/gif/webp/bmp — shown inline
      - "video": mp4/mov/m4v/webm — shown inline
      - "file":  anything else — shown as a downloadable attachment

    The path must already exist on the workspace filesystem. Typical
    flow: `code_run` produces a file under the workspace (e.g.
    /tmp/chart.png or workspace-relative), then call this tool with
    that path.

    The send happens after this turn finishes; you don't get a
    delivery receipt back, just a queued confirmation.
    """,
    category: "messaging",
    tags: ["wechat", "media", "send"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        path: Zoi.string(description: "Absolute path to the file to send"),
        kind:
          Zoi.string(description: "image | video | file")
          |> Zoi.optional()
          |> Zoi.default("file"),
        caption:
          Zoi.string(description: "Optional caption (currently ignored by WeChat)")
          |> Zoi.optional()
      })

  alias Long.Jido.Tools.Format

  @impl true
  def run(params, ctx) do
    with {:ok, session_id} <- Format.require_session_id(ctx),
         {:ok, path} <- check_path(params[:path]),
         {:ok, kind} <- parse_kind(params[:kind] || "file") do
      payload = %{path: path, kind: kind, caption: params[:caption]}
      Phoenix.PubSub.broadcast(Long.PubSub, "agent_session:#{session_id}", {:bot_send_media, payload})

      {:ok, %{status: "queued", path: path, kind: to_string(kind)}}
    else
      {:error, msg} -> {:ok, %{status: "error", msg: msg}}
    end
  end

  defp check_path(nil), do: {:error, "path is required"}
  defp check_path(""), do: {:error, "path is required"}

  defp check_path(path) when is_binary(path) do
    if File.regular?(path), do: {:ok, path}, else: {:error, "file not found: #{path}"}
  end

  defp parse_kind("image"), do: {:ok, :image}
  defp parse_kind("video"), do: {:ok, :video}
  defp parse_kind("file"), do: {:ok, :file}
  defp parse_kind(other), do: {:error, "invalid kind: #{inspect(other)}"}
end
