defmodule Long.Agent.LLMConsumer do
  @callback start(owner :: pid(), ref :: reference(), messages :: list(), tools :: list(), opts :: keyword()) ::
              {:ok, pid()} | {:error, term()}

  @moduledoc """
  One-shot process that runs a single `Long.Jido.LLMCall.call/3` on
  behalf of `Long.Agent.Server` and pipes the result back as a message:

      {:llm_result, ref, {:ok, classification}}
    | {:llm_result, ref, {:error, exception}}

  The owner (Server) `Process.monitor`s the returned pid; the `DOWN`
  signal that arrives if the process crashes covers the case where the
  call itself blew up before the `{:llm_result, ...}` send had a chance
  to run. The owner can also kill the consumer (`Process.exit(pid, :kill)`)
  to abort an in-flight turn — the kill produces a `DOWN` and no
  `:llm_result`, which the Server handles the same way as any other
  premature exit.

  Retries (transient 5xx / 429 / `Mint.TransportError`) are handled
  *inside* `LLMCall.call/3` with jittered exponential backoff, so this
  module stays a thin shell around it. After `@max_attempts` retries
  fail, `LLMCall` surfaces the original exception, which we forward as
  `{:error, exception}` rather than letting the process crash — that
  keeps the Server's state machine in charge of how to react (retry
  later, ask the user, …) instead of leaning on supervisor-restart
  semantics for what is really application-level error handling.
  """

  alias Long.Jido.LLMCall

  @task_sup Long.Agent.TaskSup

  @doc """
  Spawn a new LLM consumer. Returns `{:ok, pid}` on success — the
  caller is expected to `Process.monitor(pid)` immediately if it wants
  crash visibility (the Task is detached from the caller via
  `Task.Supervisor.start_child`).
  """
  @spec start(pid(), reference(), [ReqLLM.Message.t()], [module()], keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start(owner, ref, messages, tools, opts) do
    Task.Supervisor.start_child(@task_sup, fn ->
      result = LLMCall.call(messages, tools, opts)
      send(owner, {:llm_result, ref, result})
    end)
  end
end
