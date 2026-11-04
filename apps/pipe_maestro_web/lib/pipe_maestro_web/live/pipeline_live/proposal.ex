defmodule PipeMaestroWeb.PipelineLive.Proposal do
  @moduledoc """
  One proposal (`PipeMaestro.Proposals`): while the agent studies the
  directory, its run as a live timeline; once it ends, what it understood,
  the commands it checked, the project's configuration (editable here) and
  the proposed pipeline. Saving the project opens the pipeline form filled
  with the proposal, to review and save. A new round asks the agent again
  with the person's comment.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.JobComponents

  alias PipeMaestro.{Audit, Jobs, Projects, Proposals}
  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Projects.Project
  alias PipeMaestroWeb.Markdown

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if can?(socket.assigns.current_scope, :manage_pipelines),
      do: mount_proposal(id, socket),
      else:
        {:ok,
         socket
         |> put_flash(:error, "Só admins do workspace mudam os pipelines.")
         |> push_navigate(to: ~p"/w/#{socket.assigns.current_scope.workspace.slug}/pipelines")}
  end

  defp mount_proposal(id, socket) do
    workspace = socket.assigns.current_scope.workspace
    job = Proposals.get_proposal!(workspace, id)

    # Subscribe before reading, so nothing that happens in between is missed.
    job =
      if connected?(socket) do
        Jobs.subscribe({:job, job.id})
        Proposals.get_proposal!(workspace, id)
      else
        job
      end

    segments = job |> Jobs.list_events() |> timeline_items("all")

    {:ok,
     socket
     |> assign(page_title: "Proposta do agente", job: job, asked: Proposals.asked(job))
     |> assign(typing: nil, timeline_tail: timeline_tail(segments), feedback_form: nil)
     |> assign_result()
     |> stream(:timeline, segments)}
  end

  # Once the job ends: what it proposed, and the project form filled with it
  # (over the directory's project, when it has one).
  defp assign_result(%{assigns: %{job: job}} = socket) do
    if Job.active?(job) do
      assign(socket, result: nil, error: nil, project: nil, project_form: nil)
    else
      case Proposals.result(job) do
        {:ok, result} ->
          workspace = socket.assigns.current_scope.workspace
          project = Projects.for_directory(workspace, result.project["directory"]) || %Project{}

          socket
          |> assign(result: result, error: nil, project: project)
          |> assign(project_form: to_form(Projects.change_project(project, result.project)))

        {:error, message} ->
          assign(socket, result: nil, error: message, project: nil, project_form: nil)
      end
    end
  end

  @impl true
  def handle_info({:job_updated, %Job{} = job}, socket) do
    {:noreply,
     socket
     |> assign(job: job, typing: if(Job.active?(job), do: socket.assigns.typing))
     |> assign_result()}
  end

  def handle_info({:job_telemetry, _id}, socket), do: {:noreply, socket}

  def handle_info({:job_delta, _id, text}, socket), do: {:noreply, assign(socket, typing: text)}

  def handle_info({:job_event, event}, socket) do
    case timeline_push(socket.assigns.timeline_tail, event) do
      {:seen, _tail} ->
        {:noreply, socket}

      {segment, tail} ->
        {:noreply,
         socket
         |> stream_insert(:timeline, segment)
         |> assign(timeline_tail: tail, typing: nil)}
    end
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    case Jobs.request_cancel(socket.assigns.job) do
      {:ok, job} -> {:noreply, assign(socket, job: job)}
      {:error, :finished} -> {:noreply, put_flash(socket, :error, "A análise já terminou.")}
    end
  end

  def handle_event("validate_project", %{"project" => params}, socket) do
    changeset =
      socket.assigns.project
      |> Projects.change_project(with_directory(params, socket))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, project_form: to_form(changeset))}
  end

  def handle_event("save_project", %{"project" => params}, socket) do
    %{workspace: workspace, user: user} = socket.assigns.current_scope
    params = with_directory(params, socket)

    result =
      if socket.assigns.project.id,
        do: Projects.update_project(socket.assigns.project, params, user),
        else: Projects.create_project(workspace, params, user)

    case result do
      {:ok, project} ->
        Audit.record(workspace, user, "project.saved", project)

        {:noreply,
         socket
         |> put_flash(:info, "Projeto #{project.name} salvo. Revise o pipeline proposto.")
         |> push_navigate(
           to: ~p"/w/#{workspace.slug}/pipelines/new?proposta=#{socket.assigns.job.id}"
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, project_form: to_form(changeset))}
    end
  end

  def handle_event("open_feedback", _params, socket),
    do: {:noreply, assign(socket, feedback_form: to_form(%{"feedback" => ""}, as: "round"))}

  def handle_event("close_feedback", _params, socket),
    do: {:noreply, assign(socket, feedback_form: nil)}

  def handle_event("regenerate", %{"round" => %{"feedback" => feedback}}, socket) do
    %{workspace: workspace, user: user} = socket.assigns.current_scope
    %{job: job, asked: asked} = socket.assigns

    attrs = %{
      "runner_id" => job.runner_id,
      "directory" => asked.directory,
      "request" => asked.request,
      "feedback" => feedback
    }

    case Proposals.request(user, workspace, attrs, job) do
      {:ok, next} ->
        Audit.record(workspace, user, "proposal.requested", next)

        {:noreply,
         push_navigate(socket, to: ~p"/w/#{workspace.slug}/pipelines/proposals/#{next.id}")}

      {:error, changeset} ->
        message =
          changeset
          |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
          |> Map.values()
          |> List.flatten()
          |> Enum.join("; ")

        {:noreply, put_flash(socket, :error, "Não foi possível gerar de novo: #{message}")}
    end
  end

  # The directory is the one analysed, not a field the person changes here.
  defp with_directory(params, socket),
    do: Map.put(params, "directory", socket.assigns.asked.directory)

  defp stage_list(%{"stages" => stages}) when is_list(stages), do: stages
  defp stage_list(_pipeline), do: []

  defp gate_lines(stage), do: stage |> Map.get("gates_text", "") |> String.split("\n", trim: true)

  defp delivery_label("pr"), do: "Pull request"
  defp delivery_label("commit"), do: "Commit por etapa"
  defp delivery_label(_none), do: "Sem entrega"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:pipelines}
      title="Proposta do agente"
    >
      <:actions>
        <.button
          link_type="live_redirect"
          to={~p"/w/#{@current_scope.workspace.slug}/pipelines"}
          size="sm"
          variant="ghost"
          color="gray"
          icon="hero-arrow-left"
          data-testid="back-to-pipelines"
        >
          Pipelines
        </.button>
        <.button
          :if={Job.active?(@job)}
          size="sm"
          variant="outline"
          color="danger"
          icon="hero-stop"
          phx-click="cancel"
          data-testid="proposal-cancel"
        >
          Cancelar
        </.button>
        <.button
          :if={!Job.active?(@job)}
          size="sm"
          variant="outline"
          icon="hero-arrow-path"
          phx-click="open_feedback"
          data-testid="proposal-regenerate"
        >
          Gerar de novo com ajustes
        </.button>
      </:actions>

      <.card variant="outline" class="mb-6">
        <.card_content>
          <div class="flex flex-wrap items-start gap-4">
            <span class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-primary-50 text-primary-600 dark:bg-primary-950 dark:text-primary-300">
              <.icon name="hero-cpu-chip" class="size-5" />
            </span>
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-2">
                <h2 class="font-semibold text-gray-900 dark:text-white">
                  <.icon name="hero-folder-open" class="size-4 text-gray-400" />
                  <span data-testid="proposal-directory">{@asked.directory}</span>
                </h2>
                <.job_status job={@job} data-testid="proposal-status" />
                <span class="text-xs text-gray-500 dark:text-gray-400">
                  {if @job.runner, do: "no runner #{@job.runner.name}"}
                  {if @job.cost_usd, do: " · #{format_cost(@job.cost_usd)}"}
                  {if @job.duration_ms, do: " · #{format_duration(@job.duration_ms)}"}
                </span>
              </div>
              <div
                id="proposal-request"
                class="prose prose-sm mt-2 max-w-none text-gray-600 dark:prose-invert dark:text-gray-300"
                data-testid="proposal-request"
              >
                {Markdown.to_html(@asked.request)}
              </div>
            </div>
          </div>
        </.card_content>
      </.card>

      <.alert :if={@error} color="danger" class="mb-6" data-testid="proposal-error">
        {@error}
      </.alert>

      <div :if={@result} class="grid gap-6 xl:grid-cols-3">
        <div class="space-y-6 xl:col-span-2">
          <.card variant="outline">
            <.card_content>
              <.section_heading
                icon="hero-magnifying-glass"
                title="O que o agente entendeu do projeto"
              />
              <div
                id="proposal-analysis"
                phx-hook="Highlight"
                class="prose prose-sm max-w-none dark:prose-invert"
                data-testid="proposal-analysis"
              >
                {Markdown.to_html(@result.analysis)}
              </div>
            </.card_content>
          </.card>

          <.card variant="outline">
            <.card_content>
              <.section_heading
                icon="hero-squares-2x2"
                title={"Pipeline: #{@result.pipeline["name"]}"}
                description={@result.pipeline["description"]}
              />
              <p class="mb-3 flex items-center gap-1.5 text-xs text-gray-500 dark:text-gray-400">
                <.icon name="hero-rocket-launch" class="size-4" />
                {delivery_label(@result.pipeline["delivery"])}
              </p>
              <ol class="space-y-3" data-testid="proposal-stages">
                <li
                  :for={{stage, index} <- Enum.with_index(stage_list(@result.pipeline))}
                  class="rounded-lg border border-gray-200 p-3 dark:border-gray-700"
                  data-testid={"proposal-stage-#{index}"}
                >
                  <div class="flex items-center gap-2.5">
                    <span class="flex size-6 shrink-0 items-center justify-center rounded-full bg-primary-50 text-xs font-semibold text-primary-700 dark:bg-primary-950 dark:text-primary-300">
                      {index + 1}
                    </span>
                    <span class="font-medium text-gray-900 dark:text-white">{stage["name"]}</span>
                    <span class="ml-auto flex items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
                      <span :if={stage["group"]} class="flex items-center gap-1">
                        <.icon name="hero-squares-2x2" class="size-4" /> {stage["group"]}
                      </span>
                      <span :if={stage["model"]} class="flex items-center gap-1">
                        <.icon name="hero-sparkles" class="size-4" /> {stage["model"]}
                      </span>
                    </span>
                  </div>
                  <p class="mt-1.5 line-clamp-2 text-sm text-gray-600 dark:text-gray-300">
                    {stage["prompt"]}
                  </p>
                  <ul :if={gate_lines(stage) != []} class="mt-2 space-y-1">
                    <li
                      :for={gate <- gate_lines(stage)}
                      class="flex items-center gap-1.5 font-mono text-xs text-gray-600 dark:text-gray-300"
                    >
                      <.icon name="hero-shield-check" class="size-4 text-success-500" /> {gate}
                    </li>
                  </ul>
                </li>
              </ol>
            </.card_content>
          </.card>
        </div>

        <div class="space-y-6">
          <.card variant="outline">
            <.card_content>
              <.section_heading
                icon="hero-command-line"
                title="Verificações"
                description="Comandos que o agente rodou no worktree descartável."
              />
              <p
                :if={@result.checks == []}
                class="text-sm text-gray-500 dark:text-gray-400"
                data-testid="proposal-no-checks"
              >
                O agente não registrou verificações.
              </p>
              <ul class="space-y-2" data-testid="proposal-checks">
                <li :for={check <- @result.checks} class="flex items-start gap-2 text-sm">
                  <.icon
                    name={if check.passed, do: "hero-check-circle", else: "hero-x-circle"}
                    class={[
                      "mt-0.5 size-5 shrink-0",
                      if(check.passed, do: "text-success-500", else: "text-danger-500")
                    ]}
                  />
                  <div class="min-w-0">
                    <code class="break-all text-xs text-gray-800 dark:text-gray-100">
                      {check.command}
                    </code>
                    <p :if={check.note != ""} class="text-xs text-gray-500 dark:text-gray-400">
                      {check.note}
                    </p>
                  </div>
                </li>
              </ul>
            </.card_content>
          </.card>
        </div>

        <.card variant="outline" class="xl:col-span-3">
          <.card_content>
            <.section_heading
              icon="hero-folder-open"
              title={if @project.id, do: "Projeto (atualiza o existente)", else: "Projeto"}
              description={"Como #{@asked.directory} instala, testa e faz lint: as etapas usam esses comandos."}
            />
            <.form
              for={@project_form}
              id="proposal-project-form"
              phx-change="validate_project"
              phx-submit="save_project"
            >
              <div class="grid gap-4 md:grid-cols-2">
                <.icon_field
                  field={@project_form[:name]}
                  icon="hero-tag"
                  label="Nome"
                  data-testid="proposal-project-name"
                />
                <.icon_field
                  field={@project_form[:setup_command]}
                  icon="hero-play"
                  label="Comando de setup"
                  data-testid="proposal-project-setup"
                />
                <.icon_field
                  field={@project_form[:test_command]}
                  icon="hero-beaker"
                  label="Comando de testes"
                  data-testid="proposal-project-test"
                />
                <.icon_field
                  field={@project_form[:lint_command]}
                  icon="hero-sparkles"
                  label="Comando de lint"
                  data-testid="proposal-project-lint"
                />
              </div>
              <.icon_field
                field={@project_form[:copy_paths_text]}
                icon="hero-document-duplicate"
                type="textarea"
                rows="3"
                label="Copiar para o worktree (um por linha)"
                data-testid="proposal-project-copy-paths"
              />
              <.markdown_editor
                id="proposal-project-notes"
                field={@project_form[:notes]}
                label="Notas para os agentes"
                icon="hero-light-bulb"
                testid="proposal-project-notes"
                rows={6}
              />
              <div class="flex justify-end">
                <.button
                  type="submit"
                  icon="hero-arrow-right-circle"
                  data-testid="proposal-save-project"
                >
                  Salvar projeto e revisar o pipeline
                </.button>
              </div>
            </.form>
          </.card_content>
        </.card>
      </div>

      <.card variant="outline" class={if(@result, do: "mt-6", else: "")}>
        <.card_content>
          <.section_heading
            icon="hero-eye"
            title="Como o agente trabalhou"
            description={if Job.active?(@job), do: "Ao vivo, enquanto ele estuda o projeto."}
          />
          <p
            :if={@job.status == :queued}
            class="text-sm text-gray-500 dark:text-gray-400"
            data-testid="proposal-waiting"
          >
            Aguardando o runner começar…
          </p>
          <ol
            id="proposal-events"
            phx-update="stream"
            class="space-y-4"
            data-testid="proposal-events"
          >
            <.timeline_segment
              :for={{id, segment} <- @streams.timeline}
              id={id}
              timeline="proposal-events"
              segment={segment}
            />
          </ol>
          <.typing :if={@typing} text={@typing} />
        </.card_content>
      </.card>

      <.modal
        :if={@feedback_form}
        id="feedback-modal"
        title="Gerar de novo com ajustes"
        max_width="xl"
        on_cancel={JS.push("close_feedback")}
      >
        <.form for={@feedback_form} id="feedback-form" phx-submit="regenerate">
          <.markdown_editor
            id="proposal-feedback"
            field={@feedback_form[:feedback]}
            label="O que mudar na proposta"
            icon="hero-chat-bubble-left-ellipsis"
            testid="proposal-feedback"
            rows={5}
          />
          <div class="flex justify-end gap-2">
            <.button type="button" variant="ghost" color="gray" phx-click="close_feedback">
              Cancelar
            </.button>
            <.button type="submit" icon="hero-arrow-path" data-testid="proposal-feedback-submit">
              Gerar de novo
            </.button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end
end
