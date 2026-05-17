defmodule Long.Agent.SecretTest do
  use Long.DataCase, async: false

  alias Long.Agent

  describe "put_secret/1" do
    test "creates a new secret" do
      assert {:ok, s} =
               Agent.put_secret(%{
                 name: "github_personal",
                 value: "ghp_abc",
                 description: "test"
               })

      assert s.name == "github_personal"
      assert s.value == "ghp_abc"
      assert s.description == "test"
    end

    test "upserts on duplicate name" do
      {:ok, _} = Agent.put_secret(%{name: "dup", value: "v1"})
      {:ok, updated} = Agent.put_secret(%{name: "dup", value: "v2", description: "new"})

      assert updated.value == "v2"
      assert updated.description == "new"
      assert {:ok, [_]} = Agent.list_secrets()
    end

    test "rejects missing value" do
      assert {:error, _} = Agent.put_secret(%{name: "missing_val"})
    end
  end

  describe "get_secret_by_name/1" do
    test "returns the row by name" do
      {:ok, _} = Agent.put_secret(%{name: "lookup", value: "v"})
      assert {:ok, row} = Agent.get_secret_by_name("lookup")
      assert row.value == "v"
    end

    test "returns error for unknown name" do
      assert {:error, _} = Agent.get_secret_by_name("does_not_exist")
    end
  end

  describe "destroy_secret/1" do
    test "removes the row" do
      {:ok, row} = Agent.put_secret(%{name: "delete_me", value: "v"})
      assert :ok = Agent.destroy_secret(row)
      assert {:error, _} = Agent.get_secret_by_name("delete_me")
    end
  end

  describe "GraphQL exposure" do
    test "secret value is readable via the graphql tool (the whole point)" do
      {:ok, _} =
        Agent.put_secret(%{
          name: "gql_probe",
          value: "tok-123",
          description: "for the test"
        })

      q = """
      query {
        secrets {
          results { name value description }
        }
      }
      """

      assert {:ok, %{data: data}} = Absinthe.run(q, LongWeb.GraphqlSchema)

      row =
        data
        |> get_in(["secrets", "results"])
        |> Enum.find(&(&1["name"] == "gql_probe"))

      assert row["value"] == "tok-123"
      assert row["description"] == "for the test"
    end

    test "putSecret mutation upserts by name" do
      m = """
      mutation {
        putSecret(input: {name: "via_mutation", value: "v1", description: "first"}) {
          result { name value description }
          errors { message }
        }
      }
      """

      assert {:ok, %{data: %{"putSecret" => %{"errors" => [], "result" => r1}}}} =
               Absinthe.run(m, LongWeb.GraphqlSchema)

      assert r1["value"] == "v1"

      m2 = """
      mutation {
        putSecret(input: {name: "via_mutation", value: "v2", description: "second"}) {
          result { value description }
          errors { message }
        }
      }
      """

      assert {:ok, %{data: %{"putSecret" => %{"result" => r2}}}} =
               Absinthe.run(m2, LongWeb.GraphqlSchema)

      assert r2["value"] == "v2"
      assert r2["description"] == "second"
    end
  end
end
