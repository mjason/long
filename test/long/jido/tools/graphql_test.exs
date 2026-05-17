defmodule Long.Jido.Tools.GraphQLTest do
  use Long.DataCase, async: false

  alias Long.Agent
  alias Long.Jido.Tools.GraphQL

  describe "introspection" do
    test "lists generated queries" do
      {:ok, result} = GraphQL.run(%{query: ~s|{ __schema { queryType { fields { name } } } }|}, %{})

      assert result.status == "success"
      names = result.data["__schema"]["queryType"]["fields"] |> Enum.map(& &1["name"])
      assert "sessions" in names
      assert "scheduledTasks" in names
      assert "globalMemories" in names
    end

    test "lists generated mutations" do
      {:ok, result} =
        GraphQL.run(%{query: ~s|{ __schema { mutationType { fields { name } } } }|}, %{})

      assert result.status == "success"
      names = result.data["__schema"]["mutationType"]["fields"] |> Enum.map(& &1["name"])
      assert "createScheduledTask" in names
      assert "putGlobalMemory" in names
      assert "startSession" in names
    end

    test "describes ScheduledTask fields" do
      query = ~s|{ __type(name: "ScheduledTask") { fields { name } } }|
      {:ok, result} = GraphQL.run(%{query: query}, %{})

      fields =
        result.data["__type"]["fields"]
        |> Enum.map(& &1["name"])

      for expected <- ~w(id name prompt repeat scheduleTime enabled nextRunAt) do
        assert expected in fields, "expected ScheduledTask to have #{expected}"
      end
    end
  end

  describe "data round-trip" do
    setup do
      {:ok, sess} = Agent.start_session(%{title: "graphql-test"})
      {:ok, session: sess}
    end

    test "puts and reads a global memory", %{} do
      mutation = """
        mutation Put($key: String!, $value: String!) {
          putGlobalMemory(input: {
            scope: GENERAL
            key: $key
            value: $value
            kind: FACT
            importance: 3
          }) {
            result { id key value }
            errors { message }
          }
        }
      """

      {:ok, m} = GraphQL.run(%{query: mutation, variables: %{key: "gql_test_key", value: "v1"}}, %{})
      assert m.status == "success"
      assert m.data["putGlobalMemory"]["errors"] == []
      assert m.data["putGlobalMemory"]["result"]["key"] == "gql_test_key"

      {:ok, q} = GraphQL.run(%{query: ~s|{ globalMemories { results { key value } } }|}, %{})
      keys = q.data["globalMemories"]["results"] |> Enum.map(& &1["key"])
      assert "gql_test_key" in keys
    end

    test "creates a scheduled task tied to a session", %{session: sess} do
      mutation = """
        mutation Create($sid: ID!, $name: String!) {
          createScheduledTask(input: {
            sessionId: $sid
            name: $name
            prompt: "test prompt"
            repeat: DAILY
            scheduleTime: "11:00"
          }) {
            result { id name repeat scheduleTime }
            errors { message }
          }
        }
      """

      {:ok, m} =
        GraphQL.run(
          %{query: mutation, variables: %{sid: sess.id, name: "gql_test_task"}},
          %{}
        )

      assert m.status == "success", inspect(m.data["createScheduledTask"]["errors"])
      task = m.data["createScheduledTask"]["result"]
      assert task["name"] == "gql_test_task"
      assert task["repeat"] == "DAILY"
      assert task["scheduleTime"] == "11:00"
    end
  end

  describe "error surface" do
    test "syntax error returns partial status + error list" do
      {:ok, result} = GraphQL.run(%{query: "{ this is not graphql }"}, %{})
      assert result.status == "partial"
      assert is_list(result.errors)
      assert length(result.errors) > 0
    end
  end
end
