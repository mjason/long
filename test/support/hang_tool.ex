defmodule Long.Test.HangTool do
  @moduledoc """
  Test tool that blocks forever. Used to exercise
  `Long.Agent.Server`'s per-tool timeout path.
  """

  use Jido.Action,
    name: "hang_tool",
    description: "Test-only tool that sleeps forever to trigger the per-tool timeout.",
    category: "test",
    vsn: "1.0.0",
    schema: Zoi.object(%{})

  @impl true
  def run(_params, _ctx) do
    Process.sleep(:infinity)
  end
end
