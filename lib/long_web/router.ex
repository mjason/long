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

  scope "/", LongWeb do
    pipe_through :browser

    get "/", PageController, :home

    live "/chat", AgentLive.Chat
    live "/chat/:session_id", AgentLive.Chat
    live "/wechat", WechatLive.Login

    live "/manage", ManageLive, :llms
    live "/manage/llms", ManageLive, :llms
    live "/manage/memories", ManageLive, :memories
    live "/manage/skills", ManageLive, :skills
    live "/manage/sessions", ManageLive, :sessions
    live "/manage/search", ManageLive, :search
    live "/manage/credentials", ManageLive, :credentials
    live "/manage/scheduled", ManageLive, :scheduled
  end

  scope "/webhooks/feishu", LongWeb do
    pipe_through :api
    post "/", FeishuController, :receive
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:long, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: LongWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    scope "/" do
      pipe_through :browser

      oban_dashboard("/oban")
      error_tracker_dashboard("/errors")
    end
  end

  if Application.compile_env(:long, :dev_routes) do
    import AshAdmin.Router

    scope "/admin" do
      pipe_through :browser

      ash_admin "/"
    end
  end
end
