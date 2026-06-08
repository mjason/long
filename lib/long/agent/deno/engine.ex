defmodule Long.Agent.Deno.Engine do
  @moduledoc """
  Ensures the Deno binary is on disk so `code_run` (default engine) has
  something to shell out to. Boots without blocking the supervisor: if
  the binary is missing it kicks off a background download (~40 MB,
  one-time) via `Long.Agent.Deno.Installer`.

  `status/0` reports the resolved state:

    * `{:ok, :ready, path}`
    * `{:ok, :installing}`
    * `{:error, :failed}`

  `ready_path/0` returns the resolved binary path or `nil` — used by
  `Long.Agent.DenoEnv.deno_bin/0`. Mirrors `Long.Agent.Browser.Engine`.
  """

  use GenServer
  require Logger

  alias Long.Agent.Deno.Installer

  @name __MODULE__

  defstruct reply: {:ok, :installing}, task_ref: nil, path: nil

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def status(server \\ @name), do: GenServer.call(server, :status)

  @doc """
  The resolved `deno` path if installed, else `nil`. Safe to call even
  when the Engine isn't running (falls back to a no-download `locate`),
  so `DenoEnv` works in tests and minimal setups.
  """
  @spec ready_path(GenServer.server()) :: String.t() | nil
  def ready_path(server \\ @name) do
    case Process.whereis(server) && status(server) do
      {:ok, :ready, path} -> path
      _ -> Installer.locate()
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{}, {:continue, {:boot, opts}}}
  end

  @impl true
  def handle_continue({:boot, opts}, state) do
    cfg = config()
    bin_name = Keyword.get(cfg, :deno_bin, Installer.default_bin_name())
    bin_dir = Keyword.get(cfg, :deno_bin_dir, default_bin_dir())
    auto_install? = Keyword.get(opts, :auto_install, Keyword.get(cfg, :auto_install, true))

    case Installer.locate(bin_name, bin_dir) do
      path when is_binary(path) ->
        Logger.info("Deno.Engine: Deno already installed at #{path}")
        {:noreply, %{state | reply: {:ok, :ready, path}, path: path}}

      nil when auto_install? ->
        Logger.info("Deno.Engine: Deno not installed; auto-installing in background (~40 MB, one-time).")
        installer = Keyword.get(opts, :installer, &Installer.ensure_installed/1)
        task = Task.async(fn -> installer.(bin_dir: bin_dir, bin_name: bin_name) end)
        {:noreply, %{state | reply: {:ok, :installing}, task_ref: task.ref}}

      nil ->
        Logger.warning(
          "Deno.Engine: Deno not installed and auto_install: false. code_run (deno) will error " <>
            "until you install it (or set type: \"bash\" / \"python\")."
        )

        {:noreply, %{state | reply: {:error, :failed}}}
    end
  end

  @impl true
  def handle_info({ref, result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {reply, path} = install_reply(result)
    {:noreply, %{state | task_ref: nil, reply: reply, path: path}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    Logger.warning("Deno.Engine: installer task exited: #{inspect(reason)}")
    {:noreply, %{state | task_ref: nil, reply: {:error, :failed}}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.reply, state}

  defp install_reply({:ok, path}) when is_binary(path) do
    Logger.info("Deno.Engine: Deno install complete at #{path}")
    {{:ok, :ready, path}, path}
  end

  defp install_reply({:error, reason}) do
    Logger.warning("Deno.Engine: Deno auto-install failed (#{inspect(reason)}).")
    {{:error, :failed}, nil}
  end

  defp config, do: Application.get_env(:long, Long.Agent.Deno, [])

  defp default_bin_dir do
    Application.app_dir(:long, "priv/agent/bin")
  rescue
    _ -> Path.expand("priv/agent/bin", File.cwd!())
  end
end
