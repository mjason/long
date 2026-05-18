defmodule Long.Test.EchoTool do
  @moduledoc """
  Test tool that returns immediately with whatever was passed in.
  Used to exercise tool round-trips in `Long.Agent.Server` tests
  without needing a real tool to do real work.
  """

  use Jido.Action,
    name: "echo_tool",
    description: "Returns the given `text` unchanged.",
    category: "test",
    vsn: "1.0.0",
    schema: Zoi.object(%{text: Zoi.string()})

  @impl true
  def run(%{text: text}, _ctx), do: {:ok, %{text: text}}
  def run(_params, _ctx), do: {:ok, %{text: ""}}
end
