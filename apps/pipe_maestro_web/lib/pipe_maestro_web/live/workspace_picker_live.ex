defmodule PipeMaestroWeb.WorkspacePickerLive do
  @moduledoc """
  Where a user lands after signing in. With a single workspace they go straight
  to it; with several they pick one, or create another while their plan
  allows; with none they go on to create their first (ADR 0058).

  The board lives in another live_session (it loads the workspace on mount),
  so links into it are full navigations, not live redirects.
  """
  use PipeMaestroWeb, :live_view

  alias PipeMaestro.Workspaces

  @impl true
  def mount(_params, _session, socket) do
    case Workspaces.list_workspaces_for_user(socket.assigns.current_scope.user) do
      [] ->
        {:ok, redirect(socket, to: ~p"/workspaces/new")}

      [workspace] ->
        {:ok, redirect(socket, to: ~p"/w/#{workspace.slug}")}

      workspaces ->
        {:ok,
         assign(socket,
           page_title: "Seus workspaces",
           workspaces: workspaces,
           can_create?: Workspaces.can_create_workspace?(socket.assigns.current_scope.user)
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.public flash={@flash} nav={false}>
      <div class="mx-auto flex min-h-screen max-w-3xl flex-col px-6 py-10">
        <div class="flex items-center justify-between">
          <Layouts.brand />
          <div class="flex items-center gap-2">
            <.color_scheme_switch id="picker-scheme" variant="toggle" />
            <.form for={%{}} action={~p"/logout"} method="delete">
              <.button
                type="submit"
                variant="ghost"
                color="gray"
                size="sm"
                data-testid="picker-logout"
              >
                Sair
              </.button>
            </.form>
          </div>
        </div>

        <div class="flex flex-1 flex-col justify-center py-12">
          <h1 class="text-2xl font-semibold tracking-tight text-gray-900 dark:text-white">
            Olá, {@current_scope.user.name}
          </h1>

          <div>
            <p class="mt-2 text-sm text-gray-600 dark:text-gray-400">
              Escolha o workspace em que você quer trabalhar.
            </p>
            <.record_list id="workspaces" class="mt-8">
              <.record_card
                :for={workspace <- @workspaces}
                id={"workspace-#{workspace.slug}"}
                testid={"workspace-card-#{workspace.slug}"}
                href={~p"/w/#{workspace.slug}"}
              >
                <:leading>
                  <.avatar name={workspace.name} size="md" random_color shape="rounded" />
                </:leading>
                <:title>{workspace.name}</:title>
                <:meta>/w/{workspace.slug}</:meta>
              </.record_card>
            </.record_list>
          </div>

          <.button
            :if={@can_create?}
            to={~p"/workspaces/new"}
            link_type="live_redirect"
            variant="outline"
            color="gray"
            icon="hero-plus"
            class="mt-6"
            data-testid="picker-new-workspace"
          >
            Novo workspace
          </.button>
        </div>
      </div>
    </Layouts.public>
    """
  end
end
