defmodule ClaudeControlPlaneWeb.JobsLive do
  @moduledoc """
  The workspace's jobs, newest first and updated live, and the form that sends
  a new prompt to one of the runners online right now.
  """
  use ClaudeControlPlaneWeb, :live_view

  import ClaudeControlPlaneWeb.JobComponents
  import ClaudeControlPlaneWeb.RunnerComponents, only: [time_ago: 2]

  alias ClaudeControlPlane.{Jobs, Runners}
  alias ClaudeControlPlaneWeb.RunnerStatus
  alias Phoenix.Socket.Broadcast

  @impl true
  def mount(_params, _session, socket) do
    workspace = socket.assigns.current_scope.workspace

    if connected?(socket) do
      Jobs.subscribe({:workspace, workspace.id})
      RunnerStatus.subscribe(workspace.id)
    end

    {:ok,
     socket
     |> assign(page_title: "Execuções", creating: false, form: nil)
     |> load_jobs()
     |> load_online_runners()}
  end

  @impl true
  def handle_info({:job_updated, _job}, socket), do: {:noreply, load_jobs(socket)}

  def handle_info(%Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, load_online_runners(socket)}

  def handle_info(:runners_changed, socket), do: {:noreply, load_online_runners(socket)}

  @impl true
  def handle_event("open_new", _params, socket) do
    {:noreply, assign(socket, creating: true, form: to_form(Jobs.change_job(), as: "job"))}
  end

  def handle_event("close_new", _params, socket),
    do: {:noreply, assign(socket, creating: false, form: nil)}

  def handle_event("create", %{"job" => params}, socket) do
    %{user: user, workspace: workspace} = socket.assigns.current_scope

    case Jobs.create_job(user, workspace, params) do
      {:ok, job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Execução enviada para #{job.runner.name}.")
         |> push_navigate(to: ~p"/w/#{workspace.slug}/jobs/#{job.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "job"))}
    end
  end

  defp load_jobs(socket) do
    assign(socket,
      jobs: Jobs.list_jobs(socket.assigns.current_scope.workspace),
      now: DateTime.utc_now()
    )
  end

  defp load_online_runners(socket) do
    workspace = socket.assigns.current_scope.workspace
    online = RunnerStatus.online_ids(workspace.id)

    runners =
      for runner <- Runners.list_runners(workspace),
          MapSet.member?(online, runner.id),
          do: {runner.name, runner.id}

    assign(socket, online_runners: runners)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:jobs}
      title="Execuções"
    >
      <:actions>
        <.button size="sm" icon="hero-plus" phx-click="open_new" data-testid="new-job">
          Nova execução
        </.button>
      </:actions>

      <.card variant="outline">
        <.card_header
          title="Execuções do workspace"
          description="Prompts enviados aos runners e executados pelo agente na máquina deles."
        />

        <.table :if={@jobs != []} id="jobs" rows={@jobs} row_id={&"job-row-#{&1.id}"}>
          <:col :let={job} label="Prompt">
            <.link
              navigate={~p"/w/#{@current_scope.workspace.slug}/jobs/#{job.id}"}
              class="font-medium text-gray-900 hover:text-primary-600 dark:text-white dark:hover:text-primary-400"
              data-testid={"job-link-#{job.id}"}
            >
              {prompt_summary(job.prompt, 70)}
            </.link>
          </:col>
          <:col :let={job} label="Status">
            <.job_status job={job} data-testid={"job-status-#{job.id}"} />
          </:col>
          <:col :let={job} label="Runner">
            <span class="text-gray-600 dark:text-gray-300">
              {if job.runner, do: job.runner.name, else: "—"}
            </span>
          </:col>
          <:col :let={job} label="Duração">{format_duration(job.duration_ms)}</:col>
          <:col :let={job} label="Custo">
            <span class="font-mono text-xs">{format_cost(job.cost_usd)}</span>
          </:col>
          <:col :let={job} label="Criada">
            <span class="text-gray-500 dark:text-gray-400">{time_ago(job.inserted_at, @now)}</span>
          </:col>
        </.table>

        <.card_content :if={@jobs == []}>
          <.empty
            data-testid="no-jobs"
            title="Nenhuma execução ainda"
            description="Envie um prompt para um runner online e acompanhe o agente trabalhando."
          >
            <:icon><.icon name="hero-command-line" /></:icon>
            <:actions>
              <.button icon="hero-plus" phx-click="open_new">Nova execução</.button>
            </:actions>
          </.empty>
        </.card_content>
      </.card>

      <.modal
        :if={@creating}
        id="new-job-modal"
        title="Nova execução"
        max_width="lg"
        on_cancel={JS.push("close_new")}
      >
        <.alert
          :if={@online_runners == []}
          color="warning"
          class="mb-4"
          data-testid="no-online-runners"
        >
          Nenhum runner online neste workspace. Rode <code>make runner.start</code>
          numa máquina conectada.
        </.alert>

        <.form for={@form} id="new-job-form" phx-submit="create">
          <.icon_field
            field={@form[:runner_id]}
            icon="hero-server-stack"
            type="select"
            label="Runner"
            prompt="Escolha um runner online"
            options={@online_runners}
            data-testid="job-runner"
          />
          <.markdown_editor
            id="job-prompt"
            field={@form[:prompt]}
            label="Prompt"
            icon="hero-command-line"
            rows={6}
            placeholder="Ex.: crie um hello.txt com a data de hoje"
            help_text="O agente roda no workdir do runner com permissões totais."
            testid="job-prompt"
          />
          <div class="flex justify-end gap-2">
            <.button type="button" variant="ghost" color="gray" phx-click="close_new">
              Cancelar
            </.button>
            <.button type="submit" icon="hero-paper-airplane" data-testid="job-submit">
              Enviar
            </.button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end
end
