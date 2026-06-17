defmodule Long.Jido.Tools.GraphQLReflection do
  @moduledoc """
  The GraphQL tool used during a SILENT REFLECTION turn.

  Same surface as `Long.Jido.Tools.GraphQL` (it even keeps the name
  `"graphql"` so the system-prompt cheatsheet applies unchanged and the
  model uses it transparently), but it is the **structural** guarantee
  that a reflection turn can only ever touch its OWN session's memory:

    * reads are unrestricted (introspection + any query);
    * the only mutations allowed are `putSessionMemory` and
      `putWorkingCheckpoint`, AND each must carry a `sessionId` argument
      equal to the caller's session (`ctx.session_id`). Anything else —
      `putGlobalMemory` (shared across members), `createScheduledTask`,
      a mutation targeting another session — is refused before Absinthe
      ever runs it.

  Why a parser and not a prompt: in a multi-user deployment `GlobalMemory`
  is shared and unscoped, and a stray `sessionId` would let a reflection
  turn overwrite another member's L1 checkpoint / memory (which the web
  renders live). Relying on the reflection prompt to "use your own id" is
  not enforcement; this is. The field *name* is checked (so an alias can't
  hide a mutation) and the `sessionId` *value* is pinned (so a foreign id
  can't slip through, whether inline or via a GraphQL variable).
  """

  use Jido.Action,
    name: "graphql",
    description: """
    Run a GraphQL query or mutation against Long's own data layer.
    THIS IS THE PRIMARY DATA TOOL for reading and writing this session's
    memory. Reads are unrestricted and introspectable. The only writes
    allowed are to THIS session's own memory — `putSessionMemory` and
    `putWorkingCheckpoint`, each with `sessionId` set to this session.
    Any other mutation (global memory, scheduled tasks, another session)
    is rejected.

      query { sessionMemoriesFor(sessionId: "<id>") { results { key value kind importance } } }

      mutation {
        putSessionMemory(input: {
          sessionId: "<id>", key: "coffee_order",
          value: "oat flat white", kind: PREFERENCE, importance: 3
        }) { result { id } errors { message } }
      }

    Returns the raw GraphQL response (with `data` and any `errors`).
    """,
    category: "data",
    tags: ["graphql", "memory", "reflection"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        query:
          Zoi.string(
            description:
              "GraphQL query or mutation document. Reads are unrestricted; the only writes permitted are putSessionMemory / putWorkingCheckpoint for this session."
          ),
        variables:
          Zoi.object(%{})
          |> Zoi.optional()
          |> Zoi.default(%{})
      })

  alias Absinthe.Language.{Argument, Field, ObjectField, ObjectValue, OperationDefinition, StringValue, Variable}

  # The only mutations a reflection turn may run — its own session's
  # memory. Both carry a `sessionId` we pin to the caller. (Deliberately
  # NOT updateSessionMemory/destroySessionMemory: those key on a row `id`
  # we can't statically tie to this session, so they'd reopen the
  # cross-session write hole. Reflection corrects/prunes by re-`put`ting a
  # key with a new value or lower importance.)
  @allowed_mutations ~w(putSessionMemory putWorkingCheckpoint)

  @impl true
  def run(%{query: query} = params, ctx) when is_binary(query) do
    variables = stringify_keys(params[:variables] || %{})
    session_id = ctx[:session_id]

    case violation(query, variables, session_id) do
      nil ->
        Long.Jido.Tools.GraphQL.run(params, ctx)

      message ->
        {:ok, %{status: "error", data: nil, errors: [%{message: message}]}}
    end
  end

  # Returns a rejection message, or `nil` if the document is allowed.
  # Parse failures return `nil` so the real Absinthe run surfaces the
  # syntax error (a malformed doc executes nothing).
  defp violation(query, variables, session_id) do
    case Absinthe.Phase.Parse.run(query, []) do
      {:ok, %{input: %{definitions: defs}}} ->
        Enum.find_value(defs, &definition_violation(&1, variables, session_id))

      _ ->
        nil
    end
  end

  defp definition_violation(%OperationDefinition{operation: :mutation} = op, variables, session_id) do
    op.selection_set.selections
    |> Enum.find_value(&mutation_field_violation(&1, variables, session_id))
  end

  defp definition_violation(%OperationDefinition{operation: :subscription}, _vars, _sid),
    do: "Subscriptions are not allowed during silent reflection."

  defp definition_violation(_other, _vars, _sid), do: nil

  # Introspection meta-fields (`__typename`, …) are harmless beside a real
  # mutation — skip them rather than refuse the whole document.
  defp mutation_field_violation(%Field{name: "__" <> _}, _vars, _sid), do: nil

  defp mutation_field_violation(%Field{name: name} = field, variables, session_id) do
    cond do
      name not in @allowed_mutations ->
        "Mutation `#{name}` is not allowed during silent reflection. Only " <>
          "putSessionMemory / putWorkingCheckpoint (this session's own memory) " <>
          "may be written. Reads are unrestricted."

      true ->
        session_pin_violation(field, variables, session_id)
    end
  end

  # A selection that isn't a plain field (e.g. a fragment spread we can't
  # statically resolve) is refused conservatively.
  defp mutation_field_violation(_other, _vars, _sid),
    do: "Only plain mutation fields are allowed during silent reflection."

  defp session_pin_violation(field, variables, session_id) do
    case field_session_id(field, variables) do
      ^session_id when is_binary(session_id) ->
        nil

      nil ->
        "A reflection mutation must set sessionId to this session."

      _other ->
        "A reflection turn may only write its OWN session's memory; " <>
          "the sessionId does not match this session."
    end
  end

  # Pull the `input: { sessionId: ... }` value out of a mutation field,
  # resolving a GraphQL variable against `variables`. Returns the string
  # id, or nil when absent/unresolvable.
  defp field_session_id(%Field{arguments: args}, variables) do
    with %Argument{value: %ObjectValue{fields: object_fields}} <-
           Enum.find(args, &(&1.name == "input")),
         %ObjectField{value: value} <-
           Enum.find(object_fields, &(&1.name == "sessionId")) do
      resolve_value(value, variables)
    else
      _ -> nil
    end
  end

  defp resolve_value(%StringValue{value: value}, _variables), do: value
  defp resolve_value(%Variable{name: name}, variables), do: variables[name]
  defp resolve_value(_value, _variables), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp stringify_keys(other), do: other
end
