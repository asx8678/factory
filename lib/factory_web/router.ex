defmodule FactoryWeb.Router do
  use FactoryWeb, :router

  pipeline :browser do
    plug FactoryWeb.Plugs.HostCheck
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FactoryWeb.Layouts, :root}
    plug :protect_from_forgery
    # Agents' replies are markdown, and an image in one would load from wherever it
    # points, carrying what's in its address: images come only from Factory itself.
    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "img-src 'self' data: blob:; object-src 'none'; base-uri 'self'"
    }
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Factory's own names only, as for the pages: a page elsewhere pointing its name at
  # 127.0.0.1 could otherwise call the tools from the browser. Kiro and pi call
  # 127.0.0.1 (`Factory.PlanTools.url/0`).
  pipeline :mcp do
    plug FactoryWeb.Plugs.HostCheck
  end

  scope "/", FactoryWeb do
    pipe_through :browser

    live "/", ChatLive
    live "/chat", ChatLive
    live "/chat/:id", ChatLive
    live "/specs", SpecsLive
    live "/specs/:id", SpecLive
    live "/workflows", WorkflowsLive
    live "/workflows/:workflow_id", WorkflowsLive
    live "/workflows/:workflow_id/agents/:id", WorkflowsLive
    live "/runs", RunsLive
    live "/runs/:id", RunLive
    live "/usage", UsageLive
    live "/settings", SettingsLive
  end

  # Kiro sessions call Factory's tools here (FactoryWeb.MCP); calls carry their own token.
  scope "/" do
    pipe_through :mcp

    forward "/mcp", FactoryWeb.MCP
  end

  # Other scopes may use custom stacks.
  # scope "/api", FactoryWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:factory, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FactoryWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
