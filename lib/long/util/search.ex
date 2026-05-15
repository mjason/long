defmodule Long.Util.Search do
  @moduledoc """
  Tiny helpers shared by the keyword-ranked search paths in
  `Long.Agent.Memory.Recall` and `Long.Agent.Skill.Store`.
  """

  @doc """
  Tokenize a free-text query for substring matching: lowercase, split on
  ASCII / CJK punctuation + whitespace, drop tokens shorter than 2 chars.
  """
  @spec normalize(String.t()) :: [String.t()]
  def normalize(query) when is_binary(query) do
    query
    |> String.downcase()
    |> String.split(~r/[\s,;。，；]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 2))
  end

  @doc """
  Exponential-decay boost over time since `last_used_at`. Capped at 0.3,
  half-life ~30 days. `nil` and future timestamps return 0.
  """
  @spec recency_boost(DateTime.t() | nil) :: float()
  def recency_boost(nil), do: 0.0

  def recency_boost(%DateTime{} = ts) do
    days_ago = DateTime.diff(DateTime.utc_now(), ts, :second) / 86_400.0
    if days_ago < 0, do: 0.0, else: max(0.0, 0.3 * :math.exp(-days_ago / 30.0))
  end
end
