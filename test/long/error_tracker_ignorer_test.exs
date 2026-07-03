defmodule Long.ErrorTrackerIgnorerTest do
  use ExUnit.Case, async: true

  alias Long.ErrorTrackerIgnorer, as: Ignorer

  defp err(kind, reason), do: %ErrorTracker.Error{kind: kind, reason: reason}

  describe "ignore?/2 — transport/DNS noise is dropped" do
    test "Bandit transport exits (client disconnects)" do
      assert Ignorer.ignore?(err("Elixir.Bandit.TransportError", "Unrecoverable error: timeout"), %{})
      assert Ignorer.ignore?(err("Elixir.Bandit.HTTPTransport.HTTP1", "closed"), %{})
    end

    test "transport-level LLM stream failures (nxdomain, reset)" do
      reason = "Stream failed: %Finch.TransportError{reason: :nxdomain}"
      assert Ignorer.ignore?(err("Elixir.ReqLLM.Error.API.Stream", reason), %{})
    end
  end

  describe "ignore?/2 — real bugs are kept" do
    test "an API-level LLM error (no TransportError) is NOT ignored" do
      refute Ignorer.ignore?(err("Elixir.ReqLLM.Error.API.Response", "429 rate limited"), %{})
      refute Ignorer.ignore?(err("Elixir.ReqLLM.Error.API.Stream", "Stream failed: 401 unauthorized"), %{})
    end

    test "an app exception is NOT ignored" do
      refute Ignorer.ignore?(err("Elixir.FunctionClauseError", "no function clause matching"), %{})
      refute Ignorer.ignore?(err("Elixir.RuntimeError", "boom"), %{})
    end

    test "a non-Error term is not ignored" do
      refute Ignorer.ignore?(:whatever, %{})
    end
  end
end
