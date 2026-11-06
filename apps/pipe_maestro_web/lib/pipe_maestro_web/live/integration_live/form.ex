defmodule PipeMaestroWeb.IntegrationLive.Form do
  @moduledoc """
  Creates or edits a connection to a git host. A token connection is
  checked as it is saved; an OAuth one is saved and sends the person to the
  host to authorize (`PipeMaestroWeb.IntegrationOAuth`).
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.IntegrationComponents

  alias PipeMaestro.Integrations
  alias PipeMaestro.Integrations.Connection
  alias PipeMaestroWeb.IntegrationOAuth

  @impl true
  def mount(params, _session, socket) do
    scope = socket.assigns.current_scope

    if can?(scope, :manage_integrations) do
      connection =
        case params do
          %{"id" => id} -> Integrations.get_connection!(scope.workspace, id)
          _new -> %Connection{provider: "forgejo", auth_kind: "token"}
        end

      {:ok,
       socket
       |> assign(
         page_title: if(connection.id, do: "Editar conexão", else: "Nova conexão"),
         connection: connection
       )
       |> assign_form(Integrations.change_connection(connection))}
    else
      {:ok,
       socket
       |> put_flash(:error, "Só admins do workspace gerenciam as integrações.")
       |> push_navigate(to: ~p"/w/#{scope.workspace.slug}")}
    end
  end

  defp assign_form(socket, changeset) do
    assign(socket,
      form: to_form(changeset, as: "connection"),
      auth_kind: Ecto.Changeset.get_field(changeset, :auth_kind)
    )
  end

  @impl true
  def handle_event("validate", %{"connection" => params}, socket) do
    changeset =
      socket.assigns.connection
      |> Integrations.change_connection(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"connection" => params}, socket) do
    %{workspace: workspace, user: user} = socket.assigns.current_scope
    params = Map.put(params, "provider", "forgejo")

    result =
      if socket.assigns.connection.id,
        do: Integrations.update_connection(socket.assigns.connection, user, params),
        else: Integrations.create_connection(workspace, user, params)

    case result do
      {:ok, %Connection{auth_kind: "oauth"} = connection} when connection.status != "active" ->
        {:noreply, redirect(socket, external: IntegrationOAuth.authorize_url(connection, user))}

      {:ok, connection} ->
        {:noreply,
         socket
         |> put_flash(flash_kind(connection), saved_message(connection))
         |> push_navigate(to: ~p"/w/#{workspace.slug}/integrations/#{connection.id}")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp flash_kind(%Connection{status: "error"}), do: :error
  defp flash_kind(_connection), do: :info

  defp saved_message(%Connection{status: "error", last_error: error}),
    do: "Conexão salva, mas o host recusou o acesso: #{error}"

  defp saved_message(%Connection{name: name, bot_login: login}),
    do: "Conexão #{name} salva, como #{login}."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:integrations}
      title={@page_title}
    >
      <.form
        for={@form}
        id="integration-form"
        phx-change="validate"
        phx-submit="save"
        class="space-y-6"
      >
        <.card variant="outline">
          <.card_content>
            <.section_heading
              icon="hero-server-stack"
              title="Instância"
              description="Um Forgejo (ou Codeberg) que a plataforma vai usar em nome do workspace."
            />
            <div class="grid gap-4 sm:grid-cols-2">
              <.icon_field
                field={@form[:name]}
                icon="hero-tag"
                label="Nome"
                placeholder="Forgejo da empresa"
                data-testid="integration-name"
              />
              <.icon_field
                field={@form[:base_url]}
                icon="hero-globe-alt"
                label="Endereço"
                placeholder="https://git.exemplo.com"
                data-testid="integration-base-url"
              />
            </div>
            <p class="flex gap-2 text-sm text-gray-500 dark:text-gray-400">
              <.icon name="hero-information-circle" class="mt-0.5 size-4 shrink-0 text-primary-500" />
              <span>O GitHub chega depois, como um GitHub App.</span>
            </p>
          </.card_content>
        </.card>

        <.card variant="outline">
          <.card_content>
            <.section_heading
              icon="hero-key"
              title="Acesso"
              description="O Forgejo não tem apps como o GitHub: a plataforma age sempre como um usuário."
            />
            <.icon_field
              field={@form[:auth_kind]}
              icon="hero-finger-print"
              type="select"
              label="Como entrar"
              options={[
                {"Token de um usuário-bot (recomendado)", "token"},
                {"OAuth: uma pessoa autoriza pelo Forgejo", "oauth"}
              ]}
              data-testid="integration-auth-kind"
            />

            <div :if={@auth_kind == "token"}>
              <.icon_field
                field={@form[:token]}
                icon="hero-lock-closed"
                type="password"
                label="Token"
                placeholder={if @connection.id, do: "deixe em branco para manter", else: ""}
                help_text="Crie um usuário para a plataforma (ex.: pipemaestro-bot) com acesso de escrita aos repositórios, e um token dele com write:issue, write:repository e read:user. No Forgejo 15 ou mais novo, restrinja o token aos repositórios."
                data-testid="integration-token"
              />
            </div>

            <div :if={@auth_kind == "oauth"} class="space-y-4">
              <p class="flex gap-2 text-sm text-gray-600 dark:text-gray-300">
                <.icon name="hero-information-circle" class="mt-0.5 size-4 shrink-0 text-primary-500" />
                <span>
                  No Forgejo, em Configurações → Aplicações, crie uma aplicação OAuth2 com a URL de redirecionamento
                  <code class="break-all" data-testid="integration-oauth-redirect">{oauth_redirect_uri()}</code>
                  e copie aqui o Client ID e o Client Secret. Quem autorizar é quem aparece nos comentários.
                </span>
              </p>
              <div class="grid gap-4 sm:grid-cols-2">
                <.icon_field
                  field={@form[:oauth_client_id]}
                  icon="hero-identification"
                  label="Client ID"
                  data-testid="integration-oauth-client-id"
                />
                <.icon_field
                  field={@form[:oauth_client_secret]}
                  icon="hero-lock-closed"
                  type="password"
                  label="Client Secret"
                  placeholder={if @connection.id, do: "deixe em branco para manter", else: ""}
                  data-testid="integration-oauth-client-secret"
                />
              </div>
            </div>
          </.card_content>
        </.card>

        <.card variant="outline">
          <.card_content>
            <.section_heading
              icon="hero-arrows-right-left"
              title="Quem chama o Forgejo"
              description="Para a issue e o pull request mostrarem o andamento da tarefa."
            />
            <.icon_field
              field={@form[:api_mode]}
              icon="hero-cloud"
              type="select"
              label="Modo"
              options={[
                {"A plataforma (reação, comentário, labels, status e PR)", "control_plane"},
                {"O runner (para um Forgejo que a plataforma não alcança)", "runner"}
              ]}
              help_text="Com o runner, só a label dispara uma tarefa, e o retorno na issue acontece junto das etapas."
              no_margin
              data-testid="integration-api-mode"
            />
          </.card_content>
        </.card>

        <div class="sticky bottom-0 z-10 flex justify-end rounded-xl border border-gray-200 bg-white/90 px-4 py-3 shadow-lg backdrop-blur dark:border-gray-700 dark:bg-gray-900/90">
          <.button
            icon={if @auth_kind == "oauth", do: "hero-arrow-top-right-on-square", else: "hero-check"}
            data-testid="integration-save"
          >
            {if @auth_kind == "oauth", do: "Salvar e autorizar no Forgejo", else: "Salvar"}
          </.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
