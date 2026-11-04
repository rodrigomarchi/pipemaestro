defmodule PipeMaestroWeb.JobLive do
  @moduledoc """
  One job: its prompt, status and numbers, and the agent's run as a timeline
  that grows live while the runner reports events. The timeline is a stream of
  segments (strips of icons and blocks of text, `PipeMaestroWeb.JobComponents`);
  only the strip still open at its end is kept here, to grow it in place. A queued or
  running job can be canceled from here. While it runs, what it spent so far
  (`PipeMaestro.Insights.live/1`) follows the CLI's telemetry, at most every
  `@live_every` ms. Once it ends, its audit (`PipeMaestroWeb.AuditComponents`)
  shows how the agent worked, kept up to date as the CLI's telemetry arrives.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.JobComponents
  import PipeMaestroWeb.AuditComponents

  alias PipeMaestro.{Insights, Jobs}
  alias PipeMaestro.Jobs.Job
  alias PipeMaestroWeb.Markdown

  @live_every 2_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    workspace = socket.assigns.current_scope.workspace
    job = Jobs.get_job!(workspace, id)

    # Subscribe before reading, so nothing that happens in between is missed;
    # an event read and also received is shown once (`timeline_push/2`).
    job =
      if connected?(socket) do
        Jobs.subscribe({:job, job.id})
        Jobs.get_job!(workspace, id)
      else
        job
      end

    events = Jobs.list_events(job)
    segments = timeline_items(events, "all")

    {:ok,
     socket
     |> assign(page_title: "Execução", job: job, event_count: last_seq(events), typing: nil)
     |> assign(live_pending: false)
     |> assign(timeline_tail: timeline_tail(segments))
     |> assign_insights()
     |> stream(:timeline, segments)}
  end

  # What the run spent so far while it runs; the audit, once it has ended.
  defp assign_insights(%{assigns: %{job: job}} = socket) do
    if Job.active?(job),
      do: assign(socket, insights: nil, live: Insights.live(job)),
      else: assign(socket, insights: Insights.job(job), live: nil)
  end

  defp last_seq([]), do: 0
  defp last_seq(events), do: events |> List.last() |> Map.fetch!(:seq)

  @impl true
  def handle_info({:job_updated, %Job{} = job}, socket),
    do:
      {:noreply,
       socket
       |> assign(job: job, typing: if(Job.active?(job), do: socket.assigns.typing))
       |> assign_insights()}

  # While the run goes on, records come in bursts: what it spent so far is
  # read again once per `@live_every`.
  def handle_info({:job_telemetry, _id}, %{assigns: %{live_pending: true}} = socket),
    do: {:noreply, socket}

  def handle_info({:job_telemetry, _id}, %{assigns: %{live: %{}}} = socket) do
    Process.send_after(self(), :refresh_live, @live_every)
    {:noreply, assign(socket, live_pending: true)}
  end

  # Telemetry may arrive after the end: the job's totals and the audit follow.
  def handle_info({:job_telemetry, _id}, socket), do: {:noreply, reload(socket)}

  def handle_info(:refresh_live, socket),
    do: {:noreply, socket |> assign(live_pending: false) |> reload()}

  def handle_info({:job_delta, _id, text}, socket), do: {:noreply, assign(socket, typing: text)}

  # Events are numbered from 1, so the highest seq counts them (a gap only
  # when the runner lost its connection mid-run).
  #
  # A new icon joins the open strip in place (its open panel stays open); text
  # starts a block of its own.
  def handle_info({:job_event, event}, socket) do
    case timeline_push(socket.assigns.timeline_tail, event) do
      {:seen, _tail} ->
        {:noreply, socket}

      {segment, tail} ->
        {:noreply,
         socket
         |> stream_insert(:timeline, segment)
         |> assign(timeline_tail: tail, typing: nil)
         |> update(:event_count, &max(&1, event.seq))}
    end
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
                id="job-result"
                phx-hook="Highlight"
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
                <.timeline_segment
                  :for={{id, segment} <- @streams.timeline}
                  id={id}
                  timeline="job-events"
                  segment={segment}
                />
              </ol>
              <.typing :if={@typing} text={@typing} />
            </.card_content>
          </.card>

          <.job_audit :if={@insights} job={@job} insights={@insights} />
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
            <dl
              :if={@live}
              class="mt-4 space-y-3 border-t border-gray-100 pt-4 text-sm dark:border-gray-800"
              data-testid="job-live"
            >
              <p class="text-xs font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400">
                Até agora
              </p>
              <.detail label="Custo" testid="job-live-cost">{format_cost(@live.cost_usd)}</.detail>
              <.detail label="Tokens" testid="job-live-tokens">{short_number(@live.tokens)}</.detail>
              <.detail label="Requisições" testid="job-live-requests">{@live.requests}</.detail>
              <.detail label="Ferramentas" testid="job-live-tools">{@live.tool_calls}</.detail>
            </dl>
          </.card_content>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp reload(socket) do
    job = Jobs.get_job!(socket.assigns.current_scope.workspace, socket.assigns.job.id)
    socket |> assign(job: job) |> assign_insights()
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
