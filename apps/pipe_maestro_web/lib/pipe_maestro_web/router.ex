defmodule PipeMaestroWeb.Router do
  use PipeMaestroWeb, :router

  import PipeMaestroWeb.OperatorAuth
  import PipeMaestroWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PipeMaestroWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    plug :fetch_current_operator
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PipeMaestroWeb do
    pipe_through :browser

    get "/", PageController, :home
    delete "/logout", UserSessionController, :delete
  end

  scope "/", PipeMaestroWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    post "/login", UserSessionController, :create

    live_session :user_guest,
      on_mount: [{PipeMaestroWeb.UserAuth, :redirect_if_authenticated}] do
      live "/login", LoginLive
    end
  end

  scope "/", PipeMaestroWeb do
    pipe_through [:browser, :require_authenticated_user]

    # One address for every OAuth app registered on a git host.
    get "/integrations/oauth/callback", IntegrationOAuthController, :callback
    # Where GitHub sends whoever installed the platform's App.
    get "/integrations/github/setup", IntegrationOAuthController, :github_setup

    live_session :user, on_mount: [{PipeMaestroWeb.UserAuth, :require_authenticated}] do
      live "/workspaces", WorkspacePickerLive
      live "/runners/activate", ActivateRunnerLive
    end

    live_session :workspace,
      on_mount: [
        {PipeMaestroWeb.UserAuth, :require_authenticated},
        {PipeMaestroWeb.UserAuth, :require_workspace}
      ] do
      live "/w/:workspace_slug", BoardLive
      live "/w/:workspace_slug/decisions", DecisionsLive
      live "/w/:workspace_slug/usage", UsageLive
      live "/w/:workspace_slug/pull-requests", PullRequestsLive
      live "/w/:workspace_slug/audit", AuditLive
      live "/w/:workspace_slug/secrets", SecretsLive
      live "/w/:workspace_slug/integrations", IntegrationLive.Index
      live "/w/:workspace_slug/integrations/new", IntegrationLive.Form, :new
      live "/w/:workspace_slug/integrations/:id", IntegrationLive.Show
      live "/w/:workspace_slug/integrations/:id/edit", IntegrationLive.Form, :edit
      live "/w/:workspace_slug/integrations/:id/repos/:repo_id", IntegrationLive.Repo
      live "/w/:workspace_slug/runners", RunnersLive
      live "/w/:workspace_slug/runners/:id", RunnerLive
      live "/w/:workspace_slug/jobs", JobsLive
      live "/w/:workspace_slug/jobs/:id", JobLive
      live "/w/:workspace_slug/tasks", TaskLive.Index
      live "/w/:workspace_slug/tasks/:id", TaskLive.Show
      live "/w/:workspace_slug/projects", ProjectLive.Index
      live "/w/:workspace_slug/projects/new", ProjectLive.Form, :new
      live "/w/:workspace_slug/projects/:id/edit", ProjectLive.Form, :edit
      live "/w/:workspace_slug/pipelines", PipelineLive.Index
      live "/w/:workspace_slug/pipelines/new", PipelineLive.Form, :new
      live "/w/:workspace_slug/pipelines/:id", PipelineLive.Show
      live "/w/:workspace_slug/proposals", ProposalLive.Index
      live "/w/:workspace_slug/proposals/:id", ProposalLive.Show
      live "/w/:workspace_slug/notifications", NotificationLive
      live "/w/:workspace_slug/pipelines/:id/edit", PipelineLive.Form, :edit
    end
  end

  scope "/backoffice", PipeMaestroWeb.Backoffice do
    pipe_through :browser

    delete "/logout", OperatorSessionController, :delete
  end

  scope "/backoffice", PipeMaestroWeb.Backoffice do
    pipe_through [:browser, :redirect_if_operator_is_authenticated]

    post "/login", OperatorSessionController, :create

    live_session :operator_guest,
      on_mount: [{PipeMaestroWeb.OperatorAuth, :redirect_if_authenticated}] do
      live "/login", LoginLive
    end
  end

  scope "/backoffice", PipeMaestroWeb.Backoffice do
    pipe_through [:browser, :require_authenticated_operator]

    live_session :operator,
      on_mount: [{PipeMaestroWeb.OperatorAuth, :require_authenticated}] do
      live "/", WorkspaceLive.Index, :index
      live "/workspaces", WorkspaceLive.Index, :index
      live "/workspaces/new", WorkspaceLive.Index, :new
      live "/workspaces/:id/edit", WorkspaceLive.Index, :edit
      live "/workspaces/:id", WorkspaceLive.Show, :show

      live "/users", UserLive.Index, :index
      live "/users/new", UserLive.Index, :new
      live "/users/:id", UserLive.Show, :show

      live "/operators", OperatorLive.Index, :index
      live "/operators/new", OperatorLive.Index, :new
    end
  end

  scope "/", PipeMaestroWeb do
    pipe_through :api

    get "/healthz", HealthController, :index
    get "/version", HealthController, :version
    # The GitHub App's single webhook, before a connection's own.
    post "/api/integrations/github/webhook", IntegrationWebhookController, :receive_app_event
    post "/api/integrations/:connection_id/webhook", IntegrationWebhookController, :receive_event
    post "/api/runner/device/code", RunnerDeviceController, :create_code
    post "/api/runner/device/token", RunnerDeviceController, :create_token
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:pipe_maestro_web, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PipeMaestroWeb.Telemetry
    end
  end
end
