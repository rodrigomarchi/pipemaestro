defmodule ClaudeControlPlaneWeb.Router do
  use ClaudeControlPlaneWeb, :router

  import ClaudeControlPlaneWeb.OperatorAuth
  import ClaudeControlPlaneWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ClaudeControlPlaneWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    plug :fetch_current_operator
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ClaudeControlPlaneWeb do
    pipe_through :browser

    get "/", PageController, :home
    delete "/logout", UserSessionController, :delete
  end

  scope "/", ClaudeControlPlaneWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    post "/login", UserSessionController, :create

    live_session :user_guest,
      on_mount: [{ClaudeControlPlaneWeb.UserAuth, :redirect_if_authenticated}] do
      live "/login", LoginLive
    end
  end

  scope "/", ClaudeControlPlaneWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :user, on_mount: [{ClaudeControlPlaneWeb.UserAuth, :require_authenticated}] do
      live "/workspaces", WorkspacePickerLive
      live "/runners/activate", ActivateRunnerLive
    end

    live_session :workspace,
      on_mount: [
        {ClaudeControlPlaneWeb.UserAuth, :require_authenticated},
        {ClaudeControlPlaneWeb.UserAuth, :require_workspace}
      ] do
      live "/w/:workspace_slug", BoardLive
      live "/w/:workspace_slug/runners", RunnersLive
    end
  end

  scope "/backoffice", ClaudeControlPlaneWeb.Backoffice do
    pipe_through :browser

    delete "/logout", OperatorSessionController, :delete
  end

  scope "/backoffice", ClaudeControlPlaneWeb.Backoffice do
    pipe_through [:browser, :redirect_if_operator_is_authenticated]

    post "/login", OperatorSessionController, :create

    live_session :operator_guest,
      on_mount: [{ClaudeControlPlaneWeb.OperatorAuth, :redirect_if_authenticated}] do
      live "/login", LoginLive
    end
  end

  scope "/backoffice", ClaudeControlPlaneWeb.Backoffice do
    pipe_through [:browser, :require_authenticated_operator]

    live_session :operator,
      on_mount: [{ClaudeControlPlaneWeb.OperatorAuth, :require_authenticated}] do
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

  scope "/", ClaudeControlPlaneWeb do
    pipe_through :api

    get "/healthz", HealthController, :index
    post "/api/runner/device/code", RunnerDeviceController, :create_code
    post "/api/runner/device/token", RunnerDeviceController, :create_token
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:claude_control_plane_web, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ClaudeControlPlaneWeb.Telemetry
    end
  end
end
