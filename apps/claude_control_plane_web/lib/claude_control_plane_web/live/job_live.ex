defmodule ClaudeControlPlaneWeb.JobLive do
  @moduledoc """
  One job: its prompt, status and numbers, and the agent's run as a timeline
  that grows live while the runner reports events. A queued or running job can
  be canceled from here.
  """
  use ClaudeControlPlaneWeb, :live_view

  import ClaudeControlPlaneWeb.JobComponents

  alias ClaudeControlPlane.Jobs
  alias ClaudeControlPlane.Jobs.Job
  alias ClaudeControlPlaneWeb.Markdown

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    workspace = socket.assigns.current_scope.workspace
    job = Jobs.get_job!(workspace, id)

    # Subscribe before reading, so nothing that happens in between is missed;
    # an event read and also received is the same stream item.
    job =
      if connected?(socket) do
        Jobs.subscribe({:job, job.id})
        Jobs.get_job!(workspace, id)
      else
        job
      end

    events = Jobs.list_events(job)

    {:ok,
     socket
     |> assign(page_title: "Execução", job: job, event_count: last_seq(events))
     |> stream(:events, events)}
  end

  defp last_seq([]), do: 0
  defp last_seq(events), do: events |> List.last() |> Map.fetch!(:seq)

  @impl true
  def handle_info({:job_updated, %Job{} = job}, socket), do: {:noreply, assign(socket, job: job)}

  # Events are numbered from 1, so the highest seq counts them (a gap only
  # when the runner lost its connection mid-run).
  def handle_info({:job_event, event}, socket) do
    {:noreply,
     socket
     |> stream_insert(:events, event)
     |> update(:event_count, &max(&1, event.seq))}
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    case Jobs.request_cancel(socket.assigns.job) do
      {:ok, job} ->
        {:noreply, socket |> assign(job: job) |> put_flash(:info, "Cancelamento pedido.")}

      {:error, :finished} ->
        {:noreply, put_flash(socket, :error, "A execução já terminou.")}
    end
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
      title="Execução"
    >
      <:actions>
        <.button
          link_type="live_redirect"
          to={~p"/w/#{@current_scope.workspace.slug}/jobs"}
          size="sm"
          variant="ghost"
          color="gray"
          icon="hero-arrow-left"
          data-testid="back-to-jobs"
        >
          Execuções
        </.button>
        <.button
          :if={Job.active?(@job) and is_nil(@job.cancel_requested_at)}
          size="sm"
          variant="outline"
          color="danger"
          icon="hero-stop"
          phx-click="cancel"
          data-confirm="Cancelar esta execução?"
          data-testid="job-cancel"
        >
          Cancelar
        </.button>
      </:actions>

      <div class="grid gap-6 lg:grid-cols-3">
        <div class="space-y-6 lg:col-span-2">
          <.card variant="outline">
            <.card_content>
              <div class="flex items-start justify-between gap-4">
                <h2 class="text-sm font-medium text-gray-500 dark:text-gray-400">Prompt</h2>
                <.job_status job={@job} data-testid="job-status" />
              </div>
              <pre
                class="mt-2 whitespace-pre-wrap font-sans text-gray-900 dark:text-white"
                data-testid="job-prompt-text"
              >{@job.prompt}</pre>
            </.card_content>
          </.card>

          <.card :if={@job.result || @job.error} variant="outline">
            <.card_content>
              <h2 class="text-sm font-medium text-gray-500 dark:text-gray-400">
                {if @job.error, do: "Erro", else: "Resultado"}
              </h2>
              <div
                :if={@job.result}
                class="prose prose-sm mt-2 max-w-none dark:prose-invert"
                data-testid="job-result"
              >
                {Markdown.to_html(@job.result)}
              </div>
              <pre
                :if={@job.error}
                class="mt-2 whitespace-pre-wrap font-sans text-danger-700 dark:text-danger-400"
                data-testid="job-error"
              >{@job.error}</pre>
            </.card_content>
          </.card>

          <.card variant="outline">
            <.card_header title="Linha do tempo" description="O que o agente fez, em ordem.">
              <:action>
                <.badge
                  size="sm"
                  variant="outline"
                  color="gray"
                  label={"#{@event_count} eventos"}
                  data-testid="job-event-count"
                />
              </:action>
            </.card_header>
            <.card_content>
              <p
                :if={@event_count == 0}
                class="text-sm text-gray-500 dark:text-gray-400"
                data-testid="job-no-events"
              >
                {if @job.status == :queued,
                  do: "Aguardando o runner começar…",
                  else: "Nenhum evento recebido."}
              </p>
              <ol id="job-events" phx-update="stream" class="space-y-4" data-testid="job-events">
                <.job_event :for={{id, event} <- @streams.events} id={id} event={event} />
              </ol>
            </.card_content>
          </.card>
        </div>

        <.card variant="outline" class="h-fit">
          <.card_content>
            <dl class="space-y-3 text-sm">
              <.detail label="Runner" testid="job-runner-name">
                {if @job.runner, do: @job.runner.name, else: "—"}
              </.detail>
              <.detail label="Enviada por">
                {if @job.created_by_user, do: @job.created_by_user.name, else: "—"}
              </.detail>
              <.detail label="Duração" testid="job-duration">
                {format_duration(@job.duration_ms)}
              </.detail>
              <.detail label="Turnos">{@job.num_turns || "—"}</.detail>
              <.detail label="Custo" testid="job-cost">{format_cost(@job.cost_usd)}</.detail>
              <.detail label="Código de saída">{@job.exit_code || "—"}</.detail>
            </dl>
          </.card_content>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :testid, :string, default: nil
  slot :inner_block, required: true

  defp detail(assigns) do
    ~H"""
    <div class="flex justify-between gap-4">
      <dt class="text-gray-500 dark:text-gray-400">{@label}</dt>
      <dd class="text-right font-medium text-gray-900 dark:text-white" data-testid={@testid}>
        {render_slot(@inner_block)}
      </dd>
    </div>
    """
  end
end
