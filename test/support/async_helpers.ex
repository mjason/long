defmodule Long.AsyncHelpers do
  @moduledoc false

  import ExUnit.Assertions, only: [flunk: 1]

  @doc "Block until `fun.()` returns truthy or attempts exhaust; flunk if not."
  def eventually(fun, attempts \\ 20, sleep_ms \\ 25) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(sleep_ms)
        {:cont, false}
      end
    end)
    |> case do
      true -> :ok
      false -> flunk("eventually/1 condition never became true")
    end
  end
end
