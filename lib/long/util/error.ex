defmodule Long.Util.Error do
  @moduledoc false

  @doc """
  Render any term as a user-facing message string. Exceptions go
  through `Exception.message/1`; binaries pass through; everything
  else falls back to `inspect/1`.
  """
  @spec humanize(term()) :: String.t()
  def humanize(%{__exception__: true} = e), do: Exception.message(e)
  def humanize(s) when is_binary(s), do: s
  def humanize(other), do: inspect(other)
end
