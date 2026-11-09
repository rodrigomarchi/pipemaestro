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
      <:action
        label="Nova conexão"
        icon="hero-plus"
        navigate={~p"/w/#{@current_scope.workspace.slug}/integrations/new"}
        primary
        testid="integration-new"
      />

      <.record_list id="integrations" testid="integrations" empty={@connections == []}>
        <.record_card
          :for={connection <- @connections}
          id={"integration-#{connection.id}"}
          testid={"integration-#{key(connection.name)}"}
          navigate={~p"/w/#{@current_scope.workspace.slug}/integrations/#{connection.id}"}
          link_testid={"integration-link-#{key(connection.name)}"}
        >
          <:leading><.record_icon icon="hero-link" color="primary" /></:leading>
          <:title>{connection.name}</:title>
          <:badge>
            <.integration_status
              connection={connection}
              data-testid={"integration-status-#{key(connection.name)}"}
            />
          </:badge>
          <:meta>
            <.record_fact icon="hero-globe-alt" title="Host">
              {provider_name(connection.provider)} · {connection.base_url}
            </.record_fact>
            <.record_fact :if={connection.bot_login} icon="hero-user-circle" title="Conta do bot">
              como {connection.bot_login}
            </.record_fact>
          </:meta>
          <:aside>
            <.record_metric icon="hero-key" title="Autenticação">
              {auth_name(connection.auth_kind)}
            </.record_metric>
            <.record_metric icon="hero-arrows-right-left" title="Modo da API">
              {api_mode_name(connection.api_mode)}
            </.record_metric>
            <.record_metric icon="hero-folder" title="Repositórios vinculados">
              {plural(Map.get(@repo_counts, connection.id, 0), "repositório", "repositórios")}
            </.record_metric>
          </:aside>
        </.record_card>
        <:empty_state>
          <.record_empty
            testid="no-integrations"
            icon="hero-link"
            title="Nenhuma conexão ainda"
            description="Conecte um Forgejo ou um GitHub: issues dos repositórios vinculados viram tarefas, e o andamento volta para a issue e para o pull request."
          />
        </:empty_state>
      </.record_list>
    </Layouts.app>
    """
  end
end
