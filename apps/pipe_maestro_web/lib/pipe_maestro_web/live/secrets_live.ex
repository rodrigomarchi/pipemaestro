defmodule PipeMaestroWeb.SecretsLive do
  @moduledoc """
  The workspace's secrets (`PipeMaestro.Secrets`): environment
  variables for the agents, such as an MCP server's token. Admins add, replace
  and remove them; their values are never shown back.
  """
  use PipeMaestroWeb, :live_view

  alias PipeMaestro.{Audit, Secrets}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if can?(scope, :manage_runners) do
      {:ok, socket |> assign(page_title: "Segredos") |> reset_form() |> load()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Só admins do workspace gerenciam os segredos.")
       |> push_navigate(to: ~p"/w/#{scope.workspace.slug}")}
    end
  end

  @impl true
  def handle_event("save", %{"secret" => %{"name" => name, "value" => value}}, socket) do
    %{workspace: workspace, user: user} = socket.assigns.current_scope

    case Secrets.put(workspace, String.trim(name), value) do
      {:ok, secret} ->
        Audit.record(workspace, user, "secret.saved", secret)

        {:noreply,
         socket |> put_flash(:info, "Segredo #{secret.name} salvo.") |> reset_form() |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "secret"))}
    end
  end

  def handle_event("delete", %{"name" => name}, socket) do
    %{workspace: workspace, user: user} = socket.assigns.current_scope
    :ok = Secrets.delete(workspace, name)

    Audit.record(workspace, user, "secret.deleted", %{
      __struct__: Secrets.Secret,
      id: nil,
      name: name
    })

    {:noreply, socket |> put_flash(:info, "Segredo #{name} removido.") |> load()}
  end

  defp reset_form(socket),
    do: assign(socket, form: to_form(%{"name" => "", "value" => ""}, as: "secret"))

  defp load(socket),
    do: assign(socket, secrets: Secrets.list(socket.assigns.current_scope.workspace))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      notification_center={@notification_center}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:secrets}
      title="Segredos"
    >
      <div class="space-y-6">
        <.card variant="outline">
          <.card_header
            title="Variáveis de ambiente dos agentes"
            description="Vão com cada job para o runner, só em memória. Num servidor MCP do pipeline, use ${NOME}."
          />
          <.card_content>
            <p
              :if={@secrets == []}
              class="text-sm text-gray-500 dark:text-gray-400"
              data-testid="no-secrets"
            >
              Nenhum segredo ainda.
            </p>
            <.record_list :if={@secrets != []} id="secrets">
              <.record_card
                :for={secret <- @secrets}
                id={"secret-#{secret.name}"}
                testid={"secret-#{secret.name}"}
                dense
              >
                <:leading><.record_icon icon="hero-key" /></:leading>
                <:title><span class="font-mono">{secret.name}</span></:title>
                <:meta>••••••••</:meta>
                <:actions>
                  <.button
                    size="xs"
                    variant="ghost"
                    color="danger"
                    icon="hero-trash"
                    phx-click="delete"
                    phx-value-name={secret.name}
                    data-confirm={"Remover #{secret.name}?"}
                    data-testid={"secret-delete-#{secret.name}"}
                  >
                    Remover
                  </.button>
                </:actions>
              </.record_card>
            </.record_list>
          </.card_content>
        </.card>

        <.card variant="outline">
          <.card_header
            title="Adicionar ou trocar"
            description="Um nome que já existe tem o valor trocado."
          />
          <.card_content>
            <.form for={@form} id="secret-form" phx-submit="save" class="grid gap-4 sm:grid-cols-3">
              <.icon_field
                field={@form[:name]}
                icon="hero-variable"
                label="Nome"
                placeholder="GRAFANA_TOKEN"
                data-testid="secret-name"
              />
              <.icon_field
                field={@form[:value]}
                icon="hero-lock-closed"
                type="password"
                label="Valor"
                data-testid="secret-value"
              />
              <div class="flex items-end pb-4">
                <.button icon="hero-lock-closed" data-testid="secret-save">Salvar</.button>
              </div>
            </.form>
          </.card_content>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
