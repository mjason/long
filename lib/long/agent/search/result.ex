defmodule Long.Agent.Search.Result do
  @moduledoc """
  One row in a search result list. `sources` lists the engines that
  returned this URL (multi-source hits get scored higher by the fusion
  step in `Long.Agent.Search`).
  """

  @type t :: %__MODULE__{
          title: String.t() | nil,
          url: String.t(),
          snippet: String.t() | nil,
          sources: [atom()],
          score: float()
        }

  defstruct title: nil,
            url: nil,
            snippet: nil,
            sources: [],
            score: 0.0

  @doc """
  Deduplicate and order `:sources` so the JSON payload going back to the
  LLM is stable across runs.
  """
  def with_sources(%__MODULE__{sources: srcs} = r) do
    %__MODULE__{r | sources: srcs |> Enum.uniq() |> Enum.sort()}
  end
end
