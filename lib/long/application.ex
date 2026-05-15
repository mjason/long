defmodule Long.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LongWeb.Telemetry,
      Long.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:long, :ecto_repos), skip: skip_migrations?()},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:long, :ash_domains),
         Application.fetch_env!(:long, Oban)
       )},
      {Task.Supervisor, name: Long.Agent.TaskSup},
      Long.Agent.Activity,
      Long.Agent.Browser.Cli.Limiter,
      Long.Agent.Browser.Engine,
      Long.Agent.Bots.Telegram,
      Long.Agent.Bots.Wechat.Worker,
      # Start to serve requests, typically the last entry
      {DNSCluster, query: Application.get_env(:long, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Long.PubSub},
      LongWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Long.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LongWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
