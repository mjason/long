defmodule Long.Jido.Tools.FileWrite do
  @moduledoc "Jido.Action port of `Long.Agent.Tools.FileWrite`."

  use Jido.Action,
    name: "file_write",
    description: "Write a file in full (`overwrite`/`append`/`prepend`).",
    category: "filesystem",
    tags: ["file"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        path: Zoi.string(),
        content: Zoi.string(),
        mode:
          Zoi.string(description: "overwrite | append | prepend")
          |> Zoi.optional()
          |> Zoi.default("overwrite")
      })

  alias Long.Jido.Tools.Workspace

  @impl true
  def run(params, ctx) do
    case Workspace.resolve_path(ctx, params[:path]) do
      {:error, reason} ->
        {:ok, %{status: "error", msg: reason}}

      {:ok, path} ->
        do_write(path, params[:content] || "", params[:mode] || "overwrite")
    end
  end

  defp do_write(path, content, mode) do
    File.mkdir_p!(Path.dirname(path))

    result =
      case mode do
        "append" ->
          File.write(path, content, [:append])

        "prepend" ->
          old = if File.exists?(path), do: File.read!(path), else: ""
          File.write(path, content <> old)

        _ ->
          File.write(path, content)
      end

    case result do
      :ok ->
        {:ok, %{status: "success", bytes_written: byte_size(content), path: path}}

      {:error, reason} ->
        {:ok, %{status: "error", msg: :file.format_error(reason) |> to_string()}}
    end
  end
end
