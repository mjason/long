defmodule Long.Jido.Tools.WebScan do
  @moduledoc """
  Jido.Action port of `Long.Agent.Tools.WebScan`. Requires Chrome running
  with `--remote-debugging-port=9222`. For static pages prefer `http_fetch`.
  """

  use Jido.Action,
    name: "web_scan",
    description:
      "Scan the current Chrome page via CDP. Optionally navigate to a URL first. " <>
        "Returns simplified text + clickable element list. Chrome must be running " <>
        "with --remote-debugging-port=9222.",
    category: "web",
    tags: ["cdp", "chrome"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        url: Zoi.string() |> Zoi.optional(),
        text_only: Zoi.boolean() |> Zoi.optional() |> Zoi.default(false),
        target_id: Zoi.string() |> Zoi.optional()
      })

  alias Long.Agent.Browser.{CDP, SimpHtml}

  @impl true
  def run(params, _ctx) do
    with {:ok, target} <- CDP.first_page(),
         :ok <- maybe_navigate(target, params[:url]),
         {:ok, html} <- CDP.outer_html(target),
         {:ok, simplified} <- SimpHtml.simplify(html) do
      payload = %{
        status: "success",
        url: target.url,
        title: simplified.title,
        text: simplified.text
      }

      payload =
        if params[:text_only] == true,
          do: payload,
          else: Map.put(payload, :elements, simplified.elements)

      {:ok, payload}
    else
      {:error, reason} -> {:ok, CDP.error_payload(reason)}
    end
  end

  defp maybe_navigate(_target, nil), do: :ok
  defp maybe_navigate(_target, ""), do: :ok

  defp maybe_navigate(target, url) do
    case CDP.navigate(target, url) do
      {:ok, _} ->
        Process.sleep(500)
        :ok

      err ->
        err
    end
  end
end
