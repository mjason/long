# `:live_llm` tests hit a real LLM provider over the network — opt-in only
# (run with `mix test --only live_llm`), never part of the default suite.
ExUnit.start(exclude: [:live_llm])
Ecto.Adapters.SQL.Sandbox.mode(Long.Repo, :manual)
