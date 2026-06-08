defmodule Long.Util.Duration do
  @moduledoc false

  @doc "Whole-second elapsed since `start_ms` (System.system_time(:millisecond))."
  def seconds_since(start_ms) when is_integer(start_ms) do
    max(0, div(System.system_time(:millisecond) - start_ms, 1_000))
  end

  @doc "Render a whole-second duration compactly (e.g. 45s / 3m 5s / 2h 10m)."
  def format(secs) when secs < 60, do: "#{secs}s"
  def format(secs) when secs < 3600, do: "#{div(secs, 60)}m #{rem(secs, 60)}s"
  def format(secs), do: "#{div(secs, 3600)}h #{div(rem(secs, 3600), 60)}m"
end
