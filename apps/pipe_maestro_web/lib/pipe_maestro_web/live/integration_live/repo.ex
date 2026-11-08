defmodule PipeMaestroWeb.IntegrationLive.Repo do
  @moduledoc """
  A linked repository: the project its issues become tasks in, the prefix of
  the platform's labels and the triggers (`PipeMaestro.Integrations.Trigger`),
  added and edited in place.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.IntegrationComponents
  import PipeMaestroWeb.PipelineComponents, only: [pipeline_preview: 1]

  alias PipeMaestro.{Integrations, Pipelines, Projects, Workspaces}
  alias PipeMaestro.Integrations.{Reconciler, Trigger}

  @impl true
  def mount(%{"id" => id, "repo_id" => repo_id}, _session, socket) do
    scope = socket.assigns.current_scope

    if can?(scope, :manage_integrations) do
      connection = Integrations.get_connection!(scope.workspace, id)
      repo = Integrations.get_repo!(connection, repo_id)

      {:ok,
       socket
       |> assign(
         page_title: repo.full_name,
         connection: connection,
         repo: repo,
         projects: Projects.list_projects(scope.workspace),
         pipelines: Pipelines.list_pipelines(scope.workspace),
         members: Workspaces.list_members(scope.workspace),
         editing: nil
       )
       |> assign(repo_form: to_form(Integrations.change_repo(repo)))
       |> close_trigger()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Só admins do workspace gerenciam as integrações.")
       |> push_navigate(to: ~p"/w/#{scope.workspace.slug}")}
    end
  end

  defp close_trigger(socket), do: assign(socket, editing: nil, trigger_form: nil)

  defp open_trigger(socket, trigger, changeset) do
    assign(socket,
      editing: trigger,
      trigger_form: to_form(changeset, as: "trigger"),
      trigger_kind: Ecto.Changeset.get_field(changeset, :kind),
      trigger_mode: Ecto.Changeset.get_field(changeset, :mode),
      trigger_policy: Ecto.Changeset.get_field(changeset, :author_policy)
    )
  end

  defp reload(socket) do
    repo = Integrations.get_repo!(socket.assigns.connection, socket.assigns.repo.id)
    assign(socket, repo: repo, repo_form: to_form(Integrations.change_repo(repo)))
  end

  @impl true
  def handle_event("save_repo", %{"linked_repo" => params}, socket) do
    case Integrations.update_repo(socket.assigns.repo, socket.assigns.current_scope.user, params) do
      {:ok, _repo} -> {:noreply, socket |> reload() |> put_flash(:info, "Repositório salvo.")}
      {:error, changeset} -> {:noreply, assign(socket, repo_form: to_form(changeset))}
    end
  end

  # Off the LiveView's process: a host that does not answer must not freeze the page.
  def handle_event("sync", _params, socket) do
    repo = socket.assigns.repo
    {:noreply, start_async(socket, :sync, fn -> Reconciler.sync_repo(repo) end)}
  end

  def handle_event("unlink", _params, socket) do
    %{repo: repo, connection: connection, current_scope: scope} = socket.assigns
    :ok = Integrations.unlink_repo(repo, scope.user)

    {:noreply,
     socket
     |> put_flash(:info, "#{repo.full_name} desvinculado.")
     |> push_navigate(to: ~p"/w/#{scope.workspace.slug}/integrations/#{connection.id}")}
  end

  def handle_event("new_trigger", _params, socket) do
    %{repo: repo, current_scope: %{user: user}} = socket.assigns
    trigger = Integrations.new_trigger(repo, user)

    {:noreply,
     open_trigger(
       socket,
       trigger,
       Integrations.change_trigger(repo, trigger, %{"kind" => "label"})
     )}
  end

  def handle_event("edit_trigger", %{"id" => id}, socket) do
    trigger = Enum.find(socket.assigns.repo.triggers, &(&1.id == id))

    {:noreply,
     open_trigger(socket, trigger, Integrations.change_trigger(socket.assigns.repo, trigger))}
  end

  def handle_event("cancel_trigger", _params, socket), do: {:noreply, close_trigger(socket)}

  def handle_event("validate_trigger", %{"trigger" => params}, socket) do
    changeset =
      socket.assigns.repo
      |> Integrations.change_trigger(socket.assigns.editing, params)
      |> Map.put(:action, :validate)

    {:noreply, open_trigger(socket, socket.assigns.editing, changeset)}
  end

  def handle_event("save_trigger", %{"trigger" => params}, socket) do
    %{repo: repo, editing: trigger, current_scope: %{user: user}} = socket.assigns

    case Integrations.save_trigger(repo, user, trigger, params) do
      {:ok, _trigger} ->
        {:noreply, socket |> reload() |> close_trigger() |> put_flash(:info, "Gatilho salvo.")}

      {:error, changeset} ->
        {:noreply, open_trigger(socket, trigger, changeset)}
    end
  end

  def handle_event("delete_trigger", %{"id" => id}, socket) do
    trigger = Enum.find(socket.assigns.repo.triggers, &(&1.id == id))
    :ok = Integrations.delete_trigger(trigger, socket.assigns.current_scope.user)
    {:noreply, socket |> reload() |> close_trigger() |> put_flash(:info, "Gatilho removido.")}
  end

  @impl true
  def handle_async(:sync, {:ok, taken}, socket),
    do:
      {:noreply,
       put_flash(socket, :info, "Sincronizado: #{plural(taken, "issue lida", "issues lidas")}.")}

  def handle_async(:sync, {:exit, reason}, socket),
    do: {:noreply, put_flash(socket, :error, "O host não respondeu: #{inspect(reason)}")}

  defp trigger_key(%Trigger{kind: "label", label: label}), do: "label-#{key(label)}"
  defp trigger_key(%Trigger{kind: "comment", command: command}), do: "comment-#{key(command)}"
  defp trigger_key(%Trigger{kind: kind}), do: kind

  defp trigger_detail(%Trigger{} = trigger, pipelines) do
    Enum.join(
      [
        trigger_what(trigger),
        trigger_how(trigger),
        trigger_pipeline(trigger, pipelines),
        if(trigger.author_policy == "anyone", do: "qualquer autor", else: "quem tem escrita"),
        "até #{trigger.max_per_hour}/h"
      ],
      " · "
    )
  end

  defp trigger_what(%Trigger{kind: "label", label: label}), do: "label #{label}"
  defp trigger_what(%Trigger{kind: "comment", command: command}), do: "comentário #{command}"
  defp trigger_what(%Trigger{}), do: "issue aberta"

  defp trigger_how(%Trigger{mode: "task"}), do: "tarefa direta"
  defp trigger_how(%Trigger{auto_approve: true}), do: "a IA escreve e cria"
  defp trigger_how(%Trigger{}), do: "a IA escreve, alguém revisa"

  defp trigger_pipeline(%Trigger{pipeline_id: id}, pipelines) do
    case Enum.find(pipelines, &(&1.id == id)) do
      nil -> "pipeline à escolha da IA"
      pipeline -> "pipeline #{pipeline.name}"
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
      title={@repo.full_name}
      back={
        %{
          to: ~p"/w/#{@current_scope.workspace.slug}/integrations/#{@connection.id}",
          label: @connection.name,
          testid: "repo-back"
        }
      }
    >
      <:action label="Sincronizar agora" icon="hero-arrow-path" on_click="sync" testid="repo-sync" />
      <:action
        label="Desvincular"
        icon="hero-link-slash"
        on_click="unlink"
        confirm={"Desvincular #{@repo.full_name}? As tarefas continuam; o webhook criado pela plataforma sai."}
        danger
        testid="repo-unlink"
      />

      <div class="space-y-6">
        <.card variant="outline">
          <.card_content>
            <.section_heading
              icon="hero-folder"
              title="Projeto e labels"
              description="As tarefas rodam no diretório do projeto, num runner online que o ofereça."
            />
            <.form
              for={@repo_form}
              id="repo-form"
              phx-submit="save_repo"
              class="grid gap-4 sm:grid-cols-[1fr_1fr_auto]"
            >
              <.icon_field
                field={@repo_form[:project_id]}
                icon="hero-folder"
                type="select"
                label="Projeto"
                prompt="Escolha o projeto"
                options={Enum.map(@projects, &{"#{&1.name} (#{&1.directory})", &1.id})}
                data-testid="repo-project"
              />
              <.icon_field
                field={@repo_form[:label_prefix]}
                icon="hero-tag"
                label="Prefixo das labels"
                help_text={"#{@repo.label_prefix}, #{@repo.label_prefix}:em-andamento, #{@repo.label_prefix}:pronto…"}
                data-testid="repo-label-prefix"
              />
              <div class="flex items-start pt-7">
                <.button size="sm" icon="hero-check" data-testid="repo-save">Salvar</.button>
              </div>
            </.form>
          </.card_content>
        </.card>

        <.card variant="outline">
          <.card_header
            title="Gatilhos"
            description="O que faz uma issue virar tarefa. Cada gatilho dispara uma vez por issue; tirar a label e pôr de novo dispara outra vez."
          >
            <:action>
              <.button
                :if={@editing == nil}
                size="xs"
                icon="hero-plus"
                phx-click="new_trigger"
                data-testid="trigger-new"
              >
                Novo gatilho
              </.button>
            </:action>
          </.card_header>
          <.card_content>
            <p
              :if={@repo.triggers == [] and @editing == nil}
              class="text-sm text-gray-500 dark:text-gray-400"
              data-testid="no-triggers"
            >
              Nenhum gatilho: as issues deste repositório ainda não viram tarefas.
            </p>
            <ul
              :if={@repo.triggers != []}
              class="divide-y divide-gray-100 text-sm dark:divide-gray-800"
            >
              <li
                :for={trigger <- @repo.triggers}
                class="flex flex-wrap items-center justify-between gap-3 py-3"
                data-testid={"trigger-#{trigger_key(trigger)}"}
              >
                <div class="min-w-0">
                  <p class="font-medium text-gray-900 dark:text-white">
                    {trigger_kind_name(trigger.kind)}
                    <.badge
                      :if={!trigger.enabled}
                      size="xs"
                      color="gray"
                      variant="soft"
                      label="desligado"
                    />
                  </p>
                  <p class="mt-0.5 text-xs text-gray-500 dark:text-gray-400">
                    {trigger_detail(trigger, @pipelines)}
                  </p>
                </div>
                <div class="flex gap-2">
                  <.button
                    size="xs"
                    variant="outline"
                    color="gray"
                    icon="hero-pencil-square"
                    phx-click="edit_trigger"
                    phx-value-id={trigger.id}
                    data-testid={"trigger-edit-#{trigger_key(trigger)}"}
                  >
                    Editar
                  </.button>
                  <.button
                    size="xs"
                    variant="ghost"
                    color="danger"
                    icon="hero-trash"
                    phx-click="delete_trigger"
                    phx-value-id={trigger.id}
                    data-confirm="Remover o gatilho?"
                    data-testid={"trigger-delete-#{trigger_key(trigger)}"}
                  >
                    Remover
                  </.button>
                </div>
              </li>
            </ul>

            <.form
              :if={@trigger_form}
              for={@trigger_form}
              id="trigger-form"
              phx-change="validate_trigger"
              phx-submit="save_trigger"
              class="mt-4 space-y-2 rounded-xl border border-primary-200 p-4 dark:border-primary-900"
            >
              <div class="grid gap-4 sm:grid-cols-2">
                <.icon_field
                  field={@trigger_form[:kind]}
                  icon="hero-bolt"
                  type="select"
                  label="Quando"
                  options={
                    for kind <- Trigger.kinds(@connection.api_mode),
                        do: {trigger_kind_name(kind), kind}
                  }
                  data-testid="trigger-kind"
                />
                <.icon_field
                  :if={@trigger_kind == "label"}
                  field={@trigger_form[:label]}
                  icon="hero-tag"
                  label="Label"
                  data-testid="trigger-label"
                />
                <.icon_field
                  :if={@trigger_kind == "comment"}
                  field={@trigger_form[:command]}
                  icon="hero-command-line"
                  label="Comando"
                  help_text="No começo do comentário; /comando <pipeline> escolhe o pipeline."
                  data-testid="trigger-command"
                />
              </div>
              <div class="grid gap-4 sm:grid-cols-2">
                <.icon_field
                  field={@trigger_form[:mode]}
                  icon="hero-sparkles"
                  type="select"
                  label="O que acontece"
                  options={[
                    {"A IA escreve a tarefa a partir da issue (triagem)", "triage"},
                    {"A issue vira a tarefa direto", "task"}
                  ]}
                  data-testid="trigger-mode"
                />
                <.icon_field
                  field={@trigger_form[:pipeline_id]}
                  icon="hero-squares-2x2"
                  type="select"
                  label="Pipeline"
                  prompt={if @trigger_mode == "task", do: "Escolha um pipeline", else: "A IA escolhe"}
                  options={Enum.map(@pipelines, &{&1.name, &1.id})}
                  data-testid="trigger-pipeline"
                />
              </div>
              <.pipeline_preview
                pipelines={@pipelines}
                id={@trigger_form[:pipeline_id].value}
                testid="trigger-pipeline-preview"
              />
              <.icon_field
                :if={@trigger_mode == "triage"}
                field={@trigger_form[:auto_approve]}
                icon="hero-check-badge"
                type="checkbox"
                label="Criar e iniciar a tarefa sem revisão (se a IA tiver perguntas, ela espera alguém)"
                data-testid="trigger-auto-approve"
              />
              <div class="grid gap-4 sm:grid-cols-3">
                <.icon_field
                  field={@trigger_form[:author_policy]}
                  icon="hero-shield-check"
                  type="select"
                  label="Quem dispara"
                  options={[
                    {"Quem tem escrita no repositório", "writers"},
                    {"Qualquer autor", "anyone"}
                  ]}
                  data-testid="trigger-author-policy"
                />
                <.icon_field
                  field={@trigger_form[:max_per_hour]}
                  icon="hero-clock"
                  type="number"
                  label="Até quantas por hora"
                  data-testid="trigger-max-per-hour"
                />
                <.icon_field
                  field={@trigger_form[:acting_user_id]}
                  icon="hero-user"
                  type="select"
                  label="Em nome de"
                  options={Enum.map(@members, &{&1.name, &1.id})}
                  data-testid="trigger-acting-user"
                />
              </div>
              <div
                :if={@trigger_policy == "anyone" and @trigger_kind in ["comment", "opened"]}
                class="rounded-lg bg-warning-50 p-3 text-sm text-warning-800 dark:bg-warning-950 dark:text-warning-200"
              >
                <p class="mb-2">
                  Qualquer pessoa que abra uma issue ou comente põe texto no prompt do agente e gasta o orçamento do workspace.
                </p>
                <.icon_field
                  field={@trigger_form[:confirm_anyone]}
                  icon="hero-exclamation-triangle"
                  type="checkbox"
                  label="Entendo o risco"
                  data-testid="trigger-confirm-anyone"
                />
              </div>
              <.icon_field
                field={@trigger_form[:enabled]}
                icon="hero-power"
                type="checkbox"
                label="Ligado"
                data-testid="trigger-enabled"
              />
              <div class="flex flex-wrap justify-end gap-2">
                <.button
                  type="button"
                  size="sm"
                  variant="ghost"
                  color="gray"
                  phx-click="cancel_trigger"
                >
                  Cancelar
                </.button>
                <.button size="sm" icon="hero-check" data-testid="trigger-save">Salvar gatilho</.button>
              </div>
            </.form>
          </.card_content>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
