defmodule Long.Agent.Search.Text do
  @moduledoc false

  @doc "Collapse whitespace and trim. Nil-safe."
  def clean(nil), do: ""

  def clean(text) do
    text
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc "Strip HTML tags then `clean/1`. For API responses that embed markup in snippets."
  def clean_html(nil), do: ""

  def clean_html(text) do
    text
    |> to_string()
    |> String.replace(~r/<[^>]+>/, "")
    |> clean()
  end
end
