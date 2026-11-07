defmodule PipeMaestroWeb.IntegrationLive.Index do
  @moduledoc """
  The workspace's integrations with git hosts (`PipeMaestro.Integrations`):
  each connection with its status, who it signs in as and how many
  repositories it links. Only admins see it.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.IntegrationComponents

  alias PipeMaestro.Integrations

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if can?(scope, :manage_integrations) do
      {:ok,
       assign(socket,
         page_title: "Integrações",
         connections: Integrations.list_connections(scope.workspace),
         repo_counts: Integrations.repo_counts(scope.workspace)
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "Só admins do workspace gerenciam as integrações.")
       |> push_navigate(to: ~p"/w/#{scope.workspace.slug}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      notification_center={@notification_center}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:integrations}
      title="Integrações"
    >
      <:actions>
        <.button
          size="sm"
          icon="hero-plus"
          link_type="live_redirect"
          to={~p"/w/#{@current_scope.workspace.slug}/integrations/new"}
          data-testid="integration-new"
        >
          Nova conexão
        </.button>
      </:actions>

      <.card variant="outline">
        <.card_header
          title="Hosts git conectados"
          description="Issues dos repositórios vinculados viram tarefas, e o andamento volta para a issue e para o pull request."
        />
        <.card_content>
          <div
            :if={@connections == []}
            class="flex flex-col items-center gap-3 py-8 text-center"
            data-testid="no-integrations"
          >
            <.icon name="hero-link" class="size-8 text-gray-400" />
            <p class="text-sm text-gray-500 dark:text-gray-400">
              Nenhuma conexão ainda. Conecte um Forgejo para começar.
            </p>
          </div>

          <ul :if={@connections != []} class="divide-y divide-gray-100 dark:divide-gray-800">
            <li
              :for={connection <- @connections}
              class="flex flex-wrap items-center justify-between gap-3 py-3"
              data-testid={"integration-#{key(connection.name)}"}
            >
              <div class="min-w-0">
                <.link
                  navigate={~p"/w/#{@current_scope.workspace.slug}/integrations/#{connection.id}"}
                  class="font-medium text-gray-900 hover:underline dark:text-white"
                  data-testid={"integration-link-#{key(connection.name)}"}
                >
                  {connection.name}
                </.link>
                <p class="mt-0.5 truncate text-xs text-gray-500 dark:text-gray-400">
                  {provider_name(connection.provider)} · {connection.base_url}
                  <span :if={connection.bot_login}>· como {connection.bot_login}</span>
                </p>
              </div>
              <div class="flex flex-wrap items-center gap-2">
                <.badge
                  size="xs"
                  color="gray"
                  variant="outline"
                  label={auth_name(connection.auth_kind)}
                />
                <.badge
                  size="xs"
                  color="gray"
                  variant="outline"
                  label={api_mode_name(connection.api_mode)}
                />
                <span class="text-xs text-gray-500 dark:text-gray-400">
                  {plural(Map.get(@repo_counts, connection.id, 0), "repositório", "repositórios")}
                </span>
                <.integration_status
                  connection={connection}
                  data-testid={"integration-status-#{key(connection.name)}"}
                />
              </div>
            </li>
          </ul>
        </.card_content>
      </.card>
    </Layouts.app>
    """
  end
end
