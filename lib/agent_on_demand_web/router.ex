defmodule AgentOnDemandWeb.Router do
  use AgentOnDemandWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: AgentOnDemandWeb.ApiSpec
  end

  pipeline :authed_api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: AgentOnDemandWeb.ApiSpec
    plug AgentOnDemandWeb.Plugs.AdminAuth
    plug AgentOnDemandWeb.Plugs.RateLimit, bucket: "api", max: 600
    plug AgentOnDemandWeb.Plugs.Audit
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AgentOnDemandWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :authed_browser do
    plug AgentOnDemandWeb.Plugs.SessionAuth
  end

  scope "/", AgentOnDemandWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  # OpenAPI spec + Swagger UI. Public so that doc tooling (and the
  # CLI's potential `aod openapi` subcommand) can fetch them without a
  # token. Swagger UI itself doesn't expose data — it only renders the
  # spec and lets you "Authorize" with a bearer token to try calls.
  scope "/api" do
    pipe_through :api

    get "/openapi.json", OpenApiSpex.Plug.RenderSpec, []
    get "/docs", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi.json"
  end

  # Public browser routes (login)
  scope "/", AgentOnDemandWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    post "/logout", SessionController, :delete
    get "/logout", SessionController, :delete
  end

  # Authenticated UI
  scope "/", AgentOnDemandWeb do
    pipe_through [:browser, :authed_browser]

    live_session :ui, on_mount: {AgentOnDemandWeb.Plugs.SessionAuth, :require_admin} do
      live "/", ConversationsLive.Index, :index
      live "/conversations/new", ConversationsLive.New, :new
      live "/conversations/:id", ConversationsLive.Show, :show
      live "/agents", AgentsLive.Index, :index
      live "/agents/new", AgentsLive.Form, :new
      live "/agents/:id/edit", AgentsLive.Form, :edit
      live "/environments", EnvironmentsLive.Index, :index
      live "/environments/new", EnvironmentsLive.Form, :new
      live "/environments/:id/edit", EnvironmentsLive.Form, :edit
      live "/audit", AuditLive.Index, :index
    end
  end

  scope "/api", AgentOnDemandWeb do
    pipe_through :authed_api

    resources "/environments", EnvironmentController, except: [:new, :edit] do
      resources "/secrets", SecretController, only: [:index, :create, :delete]
    end

    resources "/agents", AgentController, except: [:new, :edit]

    resources "/conversations", ConversationController, only: [:index, :show, :create, :delete] do
      post "/prompts", ConversationController, :prompt, as: :prompt
      post "/interrupt", ConversationController, :interrupt, as: :interrupt
      post "/terminate", ConversationController, :terminate, as: :terminate
      get "/stream", ConversationController, :stream, as: :stream
      get "/turns", ConversationController, :turns, as: :turns
    end
  end

  if Application.compile_env(:agent_on_demand, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:browser]
      live_dashboard "/dashboard", metrics: AgentOnDemandWeb.Telemetry
    end
  end
end
