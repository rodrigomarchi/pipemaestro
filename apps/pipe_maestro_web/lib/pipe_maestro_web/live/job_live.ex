defmodule PipeMaestroWeb.JobLive do
  @moduledoc """
  One job, drawn as a pipeline (`PipeMaestroWeb.PipelineComponents`): its
  entry (the prompt, who sent it and where it runs), the agent at work, its
  result and its end (duration, turns, cost). Each place opens a drawer, kept
  in the URL as `?no=<place>`; the browser's back closes it. Its status and
  cost sit beside the title.

  The agent's place carries the run as it goes (its events, what it spent so
  far, what it is typing) and opens on its timeline, a stream of segments
  (strips of icons and blocks of text, `PipeMaestroWeb.JobComponents`); only
  the strip still open at its end is kept here, to grow it in place. Every
  drawer stays on the page, hidden while closed, so the stream keeps growing.
  Once the run ends, its audit (`PipeMaestroWeb.AuditComponents`) is a tab
  of the agent's drawer, kept up to date as the CLI's telemetry arrives.
  While it runs, what it spent so far (`PipeMaestro.Insights.live/1`)
  follows the CLI's telemetry, at most every `@live_every` ms. A queued or
  running job can be canceled from here.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.JobComponents
  import PipeMaestroWeb.AuditComponents
  import PipeMaestroWeb.AgentOutput, only: [agent_output: 1]
  import PipeMaestroWeb.TabComponents, only: [tab_panel: 1]

  import PipeMaestroWeb.PipelineComponents,
    only: [chosen_tab: 2, drawer_tabs: 1, place_node: 1, rail_item: 1, side_panel: 1]

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
     |> assign(node: nil, node_tab: nil)
     |> assign(live_pending: false)
     |> assign(timeline_tail: timeline_tail(segments))
     |> assign_insights()
     |> stream(:timeline, segments)}
  end

  @nodes ~w(entrada agente resultado fim)

  # The old tabs (`?aba=`) lead to the place that holds them now.
  @tab_nodes %{
    "prompt" => {"entrada", nil},
    "linha-do-tempo" => {"agente", "linha-do-tempo"},
    "auditoria" => {"agente", "auditoria"},
    "resultado" => {"resultado", nil},
    "resumo" => {"fim", nil}
  }

  @impl true
  def handle_params(params, _uri, socket) do
    {node, tab} =
      cond do
        params["no"] in @nodes -> {params["no"], nil}
        Map.has_key?(@tab_nodes, params["aba"]) -> Map.fetch!(@tab_nodes, params["aba"])
        true -> {nil, nil}
      end

    tab = tab || if(node == socket.assigns.node, do: socket.assigns.node_tab)
    {:noreply, assign(socket, node: node, node_tab: tab)}
  end

  defp agent_tabs(nil), do: [{"linha-do-tempo", "Linha do tempo", "hero-queue-list"}]

  defp agent_tabs(_insights),
    do: agent_tabs(nil) ++ [{"auditoria", "Auditoria", "hero-chart-bar"}]

  defp node_path(slug, job, nil), do: ~p"/w/#{slug}/jobs/#{job.id}"
  defp node_path(slug, job, node), do: ~p"/w/#{slug}/jobs/#{job.id}?#{[no: node]}"

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
  def handle_event("close_panel", _params, socket) do
    path = node_path(socket.assigns.current_scope.workspace.slug, socket.assigns.job, nil)
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("select_tab", %{"tab" => tab}, socket),
    do: {:noreply, assign(socket, node_tab: tab)}

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
      notification_center={@notification_center}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:jobs}
      focus={Job.active?(@job)}
      title="Execução"
      back={
        %{
          to: ~p"/w/#{@current_scope.workspace.slug}/jobs",
          label: "Execuções",
          testid: "back-to-jobs"
        }
      }
    >
      <:status>
        <.job_status job={@job} data-testid="job-status" />
        <.badge
          size="sm"
          variant="outline"
          color="gray"
          label={format_cost(if @live, do: @live.cost_usd, else: @job.cost_usd)}
          data-testid="job-cost-badge"
        />
      </:status>
      <:action
        :if={Job.active?(@job) and is_nil(@job.cancel_requested_at)}
        label="Cancelar"
        icon="hero-stop"
        on_click="cancel"
        confirm="Cancelar esta execução?"
        danger
        testid="job-cancel"
      />

      <.card variant="outline">
        <.card_content>
          <ol class="relative" data-testid="job-overview">
            <.rail_item icon="hero-bolt" tone={:primary}>
              <.place_node
                title="Entrada"
                path={node_path(@current_scope.workspace.slug, @job, "entrada")}
                open={@node == "entrada"}
                testid="job-node-entrada"
              >
                {first_line(@job.prompt)}
                <span :if={@job.runner}>· em {@job.runner.name}</span>
                <span :if={@job.created_by_user}>· por {@job.created_by_user.name}</span>
              </.place_node>
            </.rail_item>

            <.rail_item icon="hero-cpu-chip" tone={agent_tone(@job)}>
              <.place_node
                title="Agente"
                path={node_path(@current_scope.workspace.slug, @job, "agente")}
                open={@node == "agente"}
                tone={if Job.active?(@job), do: :running}
                truncate={false}
                testid="job-node-agente"
              >
                <:badge><.job_status job={@job} /></:badge>
                <p class="truncate">
                  <span data-testid="job-event-count">{@event_count} eventos</span>
                  <span :if={@live}>
                    · até agora {format_cost(@live.cost_usd)} · {short_number(@live.tokens)} tokens
                    · {@live.tool_calls} {if @live.tool_calls == 1,
                      do: "ferramenta",
                      else: "ferramentas"}
                  </span>
                  <span :if={!@live && @job.num_turns}>· {@job.num_turns} turnos</span>
                  <span :if={!@live && @job.duration_ms}>
                    · {format_duration(@job.duration_ms)}
                  </span>
                </p>
                <p
                  :if={@typing}
                  class="mt-0.5 truncate italic text-gray-600 dark:text-gray-300"
                  data-testid="job-node-typing"
                >
                  {last_line(@typing)}
                </p>
              </.place_node>
            </.rail_item>

            <.rail_item icon="hero-document-check" tone={result_tone(@job)}>
              <.place_node
                title={if @job.error, do: "Erro", else: "Resultado"}
                path={node_path(@current_scope.workspace.slug, @job, "resultado")}
                open={@node == "resultado"}
                truncate={false}
                testid="job-node-resultado"
              >
                <p class={["line-clamp-2", @job.error && "text-danger-700 dark:text-danger-400"]}>
                  {result_excerpt(@job)}
                </p>
              </.place_node>
            </.rail_item>

            <.rail_item
              icon={if Job.active?(@job), do: "hero-flag", else: "hero-check-circle"}
              tone={if Job.active?(@job), do: :neutral, else: :done}
              last
            >
              <.place_node
                title="Fim"
                path={node_path(@current_scope.workspace.slug, @job, "fim")}
                open={@node == "fim"}
                testid="job-node-fim"
              >
                {format_cost(if @live, do: @live.cost_usd, else: @job.cost_usd)}
                <span :if={@job.duration_ms}>· {format_duration(@job.duration_ms)}</span>
                <span :if={@job.exit_code}>· saída {@job.exit_code}</span>
              </.place_node>
            </.rail_item>
          </ol>
        </.card_content>
      </.card>

      <.side_panel
        id="job-drawer-entrada"
        title="Entrada"
        open={@node == "entrada"}
        testid="job-drawer-entrada"
      >
        <div
          id="job-prompt-text"
          phx-hook="Highlight"
          class="prose prose-sm max-w-none dark:prose-invert prose-h1:text-lg prose-h2:text-base prose-h3:text-sm"
          data-testid="job-prompt-text"
        >
          {Markdown.to_html(@job.prompt)}
        </div>
      </.side_panel>

      <.side_panel
        id="job-drawer-agente"
        title="Agente"
        open={@node == "agente"}
        testid="job-drawer-agente"
      >
        <.drawer_tabs
          tabs={agent_tabs(@insights)}
          active={chosen_tab(agent_tabs(@insights), @node_tab)}
          testid="job"
        />
        <.tab_panel
          id="linha-do-tempo"
          active={chosen_tab(agent_tabs(@insights), @node_tab)}
          testid="job"
        >
          <.events_pruned
            :if={@job.events_pruned_at}
            class="mb-4"
            data-testid="job-events-pruned"
          />
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
        </.tab_panel>
        <.tab_panel
          :if={@insights}
          id="auditoria"
          active={chosen_tab(agent_tabs(@insights), @node_tab)}
          testid="job"
        >
          <.job_audit job={@job} insights={@insights} />
        </.tab_panel>
      </.side_panel>

      <.side_panel
        id="job-drawer-resultado"
        title={if @job.error, do: "Erro", else: "Resultado"}
        open={@node == "resultado"}
        testid="job-drawer-resultado"
      >
        <p
          :if={!@job.result and !@job.error}
          class="text-sm text-gray-500 dark:text-gray-400"
          data-testid="job-no-result"
        >
          {if Job.active?(@job),
            do: "A execução ainda não terminou.",
            else: "A execução terminou sem resultado."}
        </p>
        <.agent_output :if={@job.result} id="job-result" text={@job.result} data-testid="job-result" />
        <pre
          :if={@job.error}
          class="whitespace-pre-wrap font-sans text-danger-700 dark:text-danger-400"
          data-testid="job-error"
        >{@job.error}</pre>
      </.side_panel>

      <.side_panel id="job-drawer-fim" title="Fim" open={@node == "fim"} testid="job-drawer-fim">
        <dl class="grid gap-x-6 gap-y-3 text-sm sm:grid-cols-3">
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
          class="mt-4 grid gap-x-6 gap-y-3 border-t border-gray-100 pt-4 text-sm sm:grid-cols-3 dark:border-gray-800"
          data-testid="job-live"
        >
          <p class="col-span-full text-xs font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400">
            Até agora
          </p>
          <.detail label="Custo" testid="job-live-cost">{format_cost(@live.cost_usd)}</.detail>
          <.detail label="Tokens" testid="job-live-tokens">{short_number(@live.tokens)}</.detail>
          <.detail label="Requisições" testid="job-live-requests">{@live.requests}</.detail>
          <.detail label="Ferramentas" testid="job-live-tools">{@live.tool_calls}</.detail>
        </dl>
      </.side_panel>
    </Layouts.app>
    """
  end

  defp agent_tone(%Job{status: :queued}), do: :neutral
  defp agent_tone(%Job{status: :running}), do: :delivery
  defp agent_tone(%Job{}), do: :done

  defp result_tone(%Job{status: :succeeded}), do: :done
  defp result_tone(%Job{}), do: :neutral

  defp result_excerpt(%Job{error: error}) when is_binary(error), do: first_line(error)
  # A structured answer by its summary; any other by its first line.
  defp result_excerpt(%Job{result: result}) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, %{"resumo" => summary}} when is_binary(summary) -> first_line(summary)
      {:ok, %{"summary" => summary}} when is_binary(summary) -> first_line(summary)
      _text -> first_line(result)
    end
  end

  defp result_excerpt(%Job{} = job),
    do: if(Job.active?(job), do: "Ainda não terminou.", else: "Terminou sem resultado.")

  # The first line of a text with something in it, without its markdown marks.
  defp first_line(nil), do: ""

  defp first_line(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.find("", &(String.trim(&1) != ""))
    |> String.replace(~r/^[#>\-*\s]+/, "")
  end

  defp last_line(text),
    do: text |> String.split("\n", trim: true) |> List.last() |> Kernel.||("")

  defp reload(socket) do
    job = Jobs.get_job!(socket.assigns.current_scope.workspace, socket.assigns.job.id)
    socket |> assign(job: job) |> assign_insights()
  end

  attr :label, :string, required: true
  attr :testid, :string, default: nil
  slot :inner_block, required: true

  defp detail(assigns) do
    ~H"""
    <div class="min-w-0">
      <dt class="text-gray-500 dark:text-gray-400">{@label}</dt>
      <dd class="truncate font-medium text-gray-900 dark:text-white" data-testid={@testid}>
        {render_slot(@inner_block)}
      </dd>
    </div>
    """
  end
end
