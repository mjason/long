defmodule LongWeb.Router do
  use LongWeb, :router

  import Oban.Web.Router
  import ErrorTracker.Web.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LongWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :graphql do
    plug :accepts, ["json"]
    plug AshGraphql.Plug
  end

  scope "/", LongWeb do
    pipe_through :browser

    get "/", PageController, :home

    live "/chat", AgentLive.Chat
    live "/chat/:session_id", AgentLive.Chat
    get "/chat/media/:session_id/:name", AgentLive.MediaController, :show
    live "/wechat", WechatLive.Login

    live "/manage", ManageLive, :llms
    live "/manage/llms", ManageLive, :llms
    live "/manage/groups", ManageLive, :groups
    live "/manage/memories", ManageLive, :memories
    live "/manage/skills", ManageLive, :skills
    live "/manage/sessions", ManageLive, :sessions
    live "/manage/search", ManageLive, :search
    live "/manage/credentials", ManageLive, :credentials
    live "/manage/scheduled", ManageLive, :scheduled
    live "/manage/monitors", ManageLive, :monitors
    live "/manage/reflection", ManageLive, :reflection
    live "/manage/secrets", ManageLive, :secrets
    live "/manage/phrases", ManageLive, :phrases
  end

  scope "/webhooks/feishu", LongWeb do
    pipe_through :api
    post "/", FeishuController, :receive
  end

  # GraphQL — the AI's primary data-access channel (via the `graphql`
  # native tool) AND a generic API surface for any external client.
  # /graphql is the JSON endpoint; /graphiql is the interactive
  # playground (always on for now — slap basic auth in front in prod
  # if you don't want the schema browser exposed).
  scope "/" do
    pipe_through :graphql

    forward "/graphql", Absinthe.Plug, schema: LongWeb.GraphqlSchema

    forward "/graphiql",
            Absinthe.Plug.GraphiQL,
            schema: LongWeb.GraphqlSchema,
            interface: :playground
  end

  # Liveness probe for the background loops (scheduler tick, bot polls). No
  # pipeline so a bare uptime check (no JSON Accept header) reaches it; returns
  # 503 when a loop has gone stale — see `LongWeb.HealthController`.
  scope "/", LongWeb do
    get "/healthz", HealthController, :show
  end

  # Operator dashboards — always mounted. `/errors` in particular is
  # load-bearing: it's the only way to inspect captured exceptions.
  # If exposed to the public internet, put basic auth on these via the
  # reverse proxy (caddy / nginx / Cloudflare Access).
  import Phoenix.LiveDashboard.Router

  scope "/" do
    pipe_through :browser

    live_dashboard "/dashboard", metrics: LongWeb.Telemetry
    oban_dashboard("/oban")
    error_tracker_dashboard("/errors")
  end

  # Dev-only stuff that's intentionally not in prod.
  if Application.compile_env(:long, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    import AshAdmin.Router

    scope "/admin" do
      pipe_through :browser

      ash_admin "/"
    end
  end
end
