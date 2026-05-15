defmodule Long.Jido.Tools.WebScanTest do
  use ExUnit.Case, async: true

  alias Long.Jido.Tools.WebScan

  setup do
    table = :ets.new(:scan_cache_test, [:public, :set])
    on_exit(fn -> if :ets.info(table) != :undefined, do: :ets.delete(table) end)
    %{cache: table}
  end

  describe "cache + circuit breaker" do
    test "missing url is rejected early" do
      assert {:ok, %{status: "error", msg: "url is required"}} = WebScan.run(%{}, %{})
    end

    test "second call to the same URL returns cached payload (no Obscura spawn)", %{cache: cache} do
      url = "https://example.test/article"

      cached = %{
        status: "success",
        url: url,
        title: "Cached",
        text: "Hello cached"
      }

      :ets.insert(cache, {url, {:ok, cached}})

      assert {:ok, payload} = WebScan.run(%{url: url}, %{scan_cache: cache})
      assert payload.title == "Cached"
      assert payload.cached == true
    end

    test "after two failures the URL is circuit-broken on the third attempt", %{cache: cache} do
      url = "https://example.test/dead-link"
      :ets.insert(cache, {url, {:fail, 2}})

      assert {:ok,
              %{
                status: "error",
                circuit_broken: true,
                msg: msg
              }} = WebScan.run(%{url: url}, %{scan_cache: cache})

      assert msg =~ "keeps failing" or msg =~ "failed 2+ times"
    end

    test "failure count below the cutoff does not short-circuit", %{cache: cache} do
      url = "https://example.test/maybe-broken"
      :ets.insert(cache, {url, {:fail, 1}})

      # Without :scan_cache hit/break, run would call Cli.dump → :not_installed
      # in test config. That's fine — we just want to confirm we DON'T
      # short-circuit at 1 failure.
      assert {:ok, payload} = WebScan.run(%{url: url}, %{scan_cache: cache})
      refute Map.get(payload, :circuit_broken, false)
    end

    test "no scan_cache in ctx falls through to Cli.dump (legacy callers)", %{cache: _cache} do
      # Without :scan_cache key, run still works — just bypasses the
      # dedup/breaker layer entirely. In test env Cli isn't installed,
      # so we get the :not_installed error, not a crash.
      assert {:ok, %{status: "error"}} =
               WebScan.run(%{url: "https://example.test/x"}, %{})
    end
  end
end
