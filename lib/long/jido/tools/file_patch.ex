defmodule Long.Jido.Tools.FilePatch do
  @moduledoc "Jido.Action port of `Long.Agent.Tools.FilePatch`. Single-anchor replacement."

  use Jido.Action,
    name: "file_patch",
    description:
      "Replace an exact `old_content` snippet with `new_content` in a file. " <>
        "The anchor must appear exactly once.",
    category: "filesystem",
    tags: ["file"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        path: Zoi.string(),
        old_content: Zoi.string(),
        new_content: Zoi.string()
      })

  alias Long.Jido.Tools.Workspace

  @impl true
  def run(params, ctx) do
    old = params[:old_content] || ""
    new = params[:new_content] || ""

    cond do
      old == "" ->
        {:ok, %{status: "error", msg: "old_content must not be empty"}}

      true ->
        case Workspace.resolve_path(ctx, params[:path]) do
          {:ok, path} -> patch(path, old, new)
          {:error, reason} -> {:ok, %{status: "error", msg: reason}}
        end
    end
  end

  defp patch(path, old, new) do
    case File.read(path) do
      {:error, reason} ->
        {:ok, %{status: "error", msg: :file.format_error(reason) |> to_string()}}

      {:ok, content} ->
        count = content |> :binary.matches(old) |> length()

        cond do
          count == 0 ->
            {:ok, %{status: "error", msg: "old_content not found"}}

          count > 1 ->
            {:ok,
             %{status: "error", msg: "old_content matches #{count} sites; refine the anchor"}}

          true ->
            new_content = String.replace(content, old, new, global: false)
            File.write!(path, new_content)

            {:ok,
             %{
               status: "success",
               bytes_before: byte_size(content),
               bytes_after: byte_size(new_content)
             }}
        end
    end
  end
end
