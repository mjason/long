defmodule Long.Util.Duration do
  @moduledoc false

  @doc "Whole-second elapsed since `start_ms` (System.system_time(:millisecond))."
  def seconds_since(start_ms) when is_integer(start_ms) do
    max(0, div(System.system_time(:millisecond) - start_ms, 1_000))
  end

  @doc "Render a whole-second duration in Chinese (秒 / 分 / 小时 + 分)."
  def format_zh(secs) when secs < 60, do: "#{secs} 秒"
  def format_zh(secs) when secs < 3600, do: "#{div(secs, 60)} 分 #{rem(secs, 60)} 秒"
  def format_zh(secs), do: "#{div(secs, 3600)} 小时 #{div(rem(secs, 3600), 60)} 分"
end
