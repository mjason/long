defmodule Long.Jido.Tools.GraphQL do
  @moduledoc """
  The agent's primary data-access tool: a single GraphQL endpoint that
  exposes every Ash resource (sessions, messages, memories, scheduled
  tasks, working checkpoints, LLM configs, search configs, …) for
  read AND write through one uniform interface.

  Replaces ~10 narrow CRUD tools (`schedule_task`, `memory_remember`,
  `update_working_checkpoint`, …) with one tool that the model
  already speaks fluently: GraphQL syntax. Schema is introspectable
  (`{ __schema { queryType { fields { name } } } }`), so the agent
  can discover capabilities on its own without us maintaining tool
  descriptions.
  """

  use Jido.Action,
    name: "graphql",
    description: """
    Run a GraphQL query or mutation against Long's own data layer.
    THIS IS THE PRIMARY DATA TOOL — for anything involving sessions,
    messages, memories (session + global), working checkpoints,
    scheduled tasks, LLM/search configs, prefer this over anything else.

    Schema is fully introspectable. If unsure what's available, start with:

      query { __schema { queryType { fields { name } } } }
      query { __schema { mutationType { fields { name } } } }
      query { __type(name: "ScheduledTask") { fields { name type { name kind } } } }

    Common patterns:

      # Schedule a daily task at 11:00 UTC that fires into this session
      mutation {
        createScheduledTask(input: {
          sessionId: "<this-session-id>"
          name: "morning_brief"
          prompt: "Pull today's worklog"
          repeat: DAILY
          scheduleTime: "11:00"
        }) { result { id name nextRunAt } errors { message } }
      }

      # Remember a global preference
      mutation {
        putGlobalMemory(input: {
          scope: GENERAL, key: "user_timezone",
          value: "Asia/Shanghai", kind: PREFERENCE, importance: 4
        }) { result { id } errors { message } }
      }

      # List my scheduled tasks — list queries are paginated, rows live
      # under `results`. Cap with `first:` so you don't pull hundreds.
      query { scheduledTasksForSession(sessionId: "<id>", first: 20) {
        results { id name prompt repeat scheduleTime nextRunAt enabled }
      } }

    Returns the raw GraphQL response (with `data` and any `errors`).
    """,
    category: "data",
    tags: ["graphql", "memory", "schedule", "session", "data"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        query:
          Zoi.string(
            description:
              "GraphQL query or mutation document. Multi-line OK. Use `query { … }` for reads, `mutation { … }` for writes."
          ),
        variables:
          Zoi.object(%{})
          |> Zoi.optional()
          |> Zoi.default(%{})
      })

  @impl true
  def run(%{query: query} = params, _ctx) do
    variables = atomized_to_string(params[:variables] || %{})

    case Absinthe.run(query, LongWeb.GraphqlSchema, variables: variables) do
      {:ok, response} ->
        {:ok,
         %{
           status: status(response),
           data: response[:data],
           errors: format_errors(response[:errors])
         }}

      {:error, reason} ->
        {:ok, %{status: "error", data: nil, errors: [%{message: inspect(reason)}]}}
    end
  end

  defp status(%{errors: errors}) when is_list(errors) and errors != [], do: "partial"
  defp status(_), do: "success"

  defp format_errors(nil), do: []
  defp format_errors([]), do: []

  defp format_errors(errors) when is_list(errors) do
    Enum.map(errors, fn err ->
      # Absinthe always emits atom-keyed `%{message:, locations:, path:}`.
      %{message: err[:message] || inspect(err)}
      |> maybe_put(:path, err[:path])
      |> maybe_put(:locations, err[:locations])
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Absinthe wants string-keyed variables. The Server's `safe_atomize_keys`
  # only atomizes the top-level tool params (`:query`, `:variables`); the
  # nested map under `:variables` keeps its string keys end-to-end, so this
  # only needs to flip the top level.
  defp atomized_to_string(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp atomized_to_string(other), do: other
end
