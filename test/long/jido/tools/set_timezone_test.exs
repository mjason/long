defmodule Long.Jido.Tools.SetTimezoneTest do
  use Long.DataCase, async: false

  alias Long.Jido.Tools.SetTimezone

  test "sets a valid IANA timezone as a setting (not memory)" do
    assert {:ok, %{status: "ok", timezone: "America/New_York"}} =
             SetTimezone.run(%{timezone: "America/New_York"}, %{})

    assert Long.Agent.user_timezone() == "America/New_York"
    # It's a setting, not an agent memory.
    assert {:ok, []} = Long.Agent.list_global_memory()
  end

  test "rejects an unknown timezone, leaving the setting unchanged" do
    assert {:ok, %{status: "error", msg: msg}} =
             SetTimezone.run(%{timezone: "Mars/Olympus"}, %{})

    assert msg =~ "Unknown timezone"
    refute Long.Agent.user_timezone() == "Mars/Olympus"
  end
end
