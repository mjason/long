defmodule Long.Jido.Tools.AskUser do
  @moduledoc """
  Jido.Action port of `Long.Agent.Tools.AskUser`. Returns a result tagged
  with `ask_user: true` so the surrounding loop (`Long.Jido.Loop`) can
  detect it and halt instead of feeding the result back into the LLM.

  Hand-off semantics survive the jido migration because we treat this
  one tool specially in the loop rather than introducing a full
  `Jido.Directive` infrastructure.
  """

  use Jido.Action,
    name: "ask_user",
    description:
      "Pause and ask the human for input. The loop terminates and returns control to " <>
        "the caller (LiveView / Bot / CLI), who can resume by sending a new user message.",
    category: "control",
    tags: ["interrupt"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        question: Zoi.string(),
        candidates:
          Zoi.list(Zoi.string(), description: "Suggested replies")
          |> Zoi.optional()
      })

  @impl true
  def run(params, _ctx) do
    {:ok,
     %{
       ask_user: true,
       question: params[:question] || "请提供输入：",
       candidates: params[:candidates] || []
     }}
  end
end
