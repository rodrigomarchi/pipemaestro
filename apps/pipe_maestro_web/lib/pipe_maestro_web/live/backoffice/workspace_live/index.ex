defmodule PipeMaestroWeb.Backoffice.WorkspaceLive.Index do
  @moduledoc "Backoffice list of workspaces, with create and edit in a modal."
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.Backoffice.Components

  alias PipeMaestro.Workspaces
  alias PipeMaestro.Workspaces.Workspace

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, workspaces: Workspaces.list_workspaces())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Workspaces", workspace: nil, form: nil)
  end

  defp apply_action(socket, :new, _params) do
    workspace = %Workspace{}

    assign(socket,
      page_title: "Novo workspace",
      workspace: workspace,
      form: to_form(Workspaces.change_workspace(workspace))
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    workspace = Workspaces.get_workspace!(id)

    assign(socket,
      page_title: "Editar workspace",
      workspace: workspace,
      form: to_form(Workspaces.change_workspace(workspace))
    )
  end

  @impl true
  def handle_event("validate", %{"workspace" => params}, socket) do
    changeset = Workspaces.change_workspace(socket.assigns.workspace, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"workspace" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  defp save(socket, :new, params) do
    case Workspaces.create_workspace(params) do
      {:ok, workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, "Workspace #{workspace.name} criado.")
         |> push_navigate(to: ~p"/backoffice/workspaces/#{workspace}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save(socket, :edit, params) do
    case Workspaces.update_workspace(socket.assigns.workspace, params) do
      {:ok, workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, "Workspace #{workspace.name} atualizado.")
         |> assign(workspaces: Workspaces.list_workspaces())
         |> push_patch(to: ~p"/backoffice/workspaces")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.backoffice
      flash={@flash}
      current_operator={@current_operator}
      active={:workspaces}
      title="Workspaces"
    >
      <:action
        label="Novo workspace"
        icon="hero-plus"
        patch={~p"/backoffice/workspaces/new"}
        primary
        testid="new-workspace"
      />

      <.record_list id="workspaces" testid="workspaces" empty={@workspaces == []}>
        <.record_card
          :for={workspace <- @workspaces}
          id={"workspace-#{workspace.id}"}
          testid={"workspace-row-#{workspace.slug}"}
          navigate={~p"/backoffice/workspaces/#{workspace}"}
        >
          <:leading>
            <.avatar name={workspace.name} size="sm" random_color shape="rounded" />
          </:leading>
          <:title><span data-testid={"workspace-#{workspace.slug}"}>{workspace.name}</span></:title>
          <:meta>
            <.record_fact
              icon="hero-link"
              title="Endereço"
              mono
              testid={"workspace-address-#{workspace.slug}"}
            >
              /w/{workspace.slug}
            </.record_fact>
          </:meta>
          <:aside>
            <.record_metric
              icon="hero-users"
              label="membros"
              testid={"workspace-member-count-#{workspace.slug}"}
            >
              {workspace.member_count}
            </.record_metric>
            <.record_metric icon="hero-calendar" title="Criado em">
              {format_date(workspace.inserted_at)}
            </.record_metric>
          </:aside>
          <:actions>
            <.button
              size="xs"
              variant="ghost"
              color="gray"
              icon="hero-pencil-square"
              to={~p"/backoffice/workspaces/#{workspace}/edit"}
              link_type="live_patch"
              data-testid={"workspace-edit-#{workspace.slug}"}
            >
              Editar
            </.button>
          </:actions>
        </.record_card>
        <:empty_state>
          <.record_empty
            testid="no-workspaces"
            icon="hero-building-office-2"
            title="Nenhum workspace ainda"
            description="Crie o workspace de uma empresa para começar a adicionar usuários."
          >
            <:actions>
              <.button to={~p"/backoffice/workspaces/new"} link_type="live_patch" icon="hero-plus">
                Novo workspace
              </.button>
            </:actions>
          </.record_empty>
        </:empty_state>
      </.record_list>

      <.modal
        :if={@form}
        id="workspace-modal"
        title={@page_title}
        on_cancel={JS.patch(~p"/backoffice/workspaces")}
      >
        <.form for={@form} id="workspace-form" phx-change="validate" phx-submit="save">
          <.icon_field
            field={@form[:name]}
            icon="hero-building-office"
            label="Nome da empresa"
            placeholder="Acme Engineering"
            data-testid="workspace-name"
          />
          <.icon_field
            field={@form[:slug]}
            icon="hero-link"
            label="Endereço"
            placeholder="acme"
            data-testid="workspace-slug"
            help_text="Aparece na URL: /w/endereco. Deixe em branco para gerar a partir do nome."
          />
          <.icon_field
            field={@form[:max_running_tasks]}
            icon="hero-queue-list"
            type="number"
            min="1"
            label="Tarefas em execução ao mesmo tempo (opcional)"
            help_text="Passado esse número, novas tarefas esperam na fila."
            data-testid="workspace-max-running-tasks"
          />
          <.icon_field
            field={@form[:runner_log_retention_days]}
            icon="hero-document-text"
            type="number"
            min="0"
            max="90"
            label="Dias de log dos runners"
            help_text="Quanto tempo o log que os runners enviam fica guardado. Com 0, nenhuma linha é guardada, só os eventos."
            data-testid="workspace-runner-log-retention"
          />
          <.icon_field
            field={@form[:job_files_retention_days]}
            icon="hero-paper-clip"
            type="number"
            min="1"
            max="3650"
            label="Dias de conteúdo dos anexos (opcional)"
            help_text="Depois desse prazo, o anexo fica só com o nome. Em branco, o conteúdo fica sem limite."
            data-testid="workspace-files-retention"
          />
          <.icon_field
            field={@form[:job_files_quota_mib]}
            icon="hero-circle-stack"
            type="number"
            min="1"
            label="Cota de anexos, em MiB (opcional)"
            help_text="Passada a cota, o runner tem os novos anexos recusados. Em branco, sem cota."
            data-testid="workspace-files-quota"
          />
          <.icon_field
            field={@form[:agent_events_retention_days]}
            icon="hero-chat-bubble-left-right"
            type="number"
            min="1"
            max="3650"
            label="Dias de eventos completos do agente"
            help_text="Por quanto tempo, depois do fim do job, os eventos guardam o texto e os argumentos."
            data-testid="workspace-events-retention"
          />
          <.icon_field
            field={@form[:agent_events_after_retention]}
            icon="hero-archive-box"
            type="select"
            label="Depois desse prazo"
            options={[{"Manter só os metadados", "metadata"}, {"Apagar os eventos", "delete"}]}
            data-testid="workspace-events-after"
          />
          <div class="flex flex-wrap justify-end gap-2">
            <.button
              to={~p"/backoffice/workspaces"}
              link_type="live_patch"
              variant="ghost"
              color="gray"
              data-testid="workspace-cancel"
            >
              Cancelar
            </.button>
            <.button type="submit" phx-disable-with="Salvando…" data-testid="workspace-save">
              Salvar
            </.button>
          </div>
        </.form>
      </.modal>
    </Layouts.backoffice>
    """
  end
end
