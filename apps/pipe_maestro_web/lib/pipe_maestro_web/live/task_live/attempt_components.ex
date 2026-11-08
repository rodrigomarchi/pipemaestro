defmodule PipeMaestroWeb.TaskLive.AttemptComponents do
  @moduledoc """
  One attempt at a task's stage, as the stage's panel
  (`PipeMaestroWeb.TaskLive.StagePanel`) shows it: its status and numbers, and
  what it produced. An attempt that ended with an artifact leads with it,
  then the files it sent, and folds how it got there (environment, changes,
  feedback, answers, instructions, summary, result, commit, gates and the
  agent's steps, read only when opened). A running attempt shows the
  timeline streamed live, what the agent is typing and what it spent so far.

  The events of an attempt (`toggle_artifact`, `toggle_steps`,
  `filter_steps`) go to `target`, the panel that holds their state.
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.JobComponents,
    only: [
      steps: 1,
      timeline_items: 2,
      timeline_segment: 1,
      typing: 1,
      count_label: 3,
      format_cost: 1,
      format_duration: 1,
      format_percent: 1,
      short_number: 1
    ]

  import PipeMaestroWeb.AgentOutput, only: [agent_output: 1]
  import PipeMaestroWeb.JobFileComponents, only: [files: 1, files_failed: 1]
  import PipeMaestroWeb.QuestionnaireComponents, only: [answer_list: 1]

  import PipeMaestroWeb.TaskComponents,
    only: [stage_run_status: 1, stage_run_session: 1, changes_report: 1]

  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Tasks.StageRun
  alias PipeMaestroWeb.Markdown

  attr :run, StageRun, required: true
  attr :many, :boolean, required: true
  attr :live, :boolean, required: true
  attr :spent, :any, default: nil, doc: "what the running attempt spent so far"
  attr :streams, :any, required: true
  attr :steps, :list, default: nil
  attr :steps_filter, :string, default: "all"
  attr :raw_artifact, :boolean, default: false
  attr :files, :list, default: [], doc: "the files the attempt's job sent"
  attr :typing, :string, default: nil
  attr :workspace_slug, :string, required: true
  attr :target, :any, default: nil, doc: "where the attempt's own events go (`phx-target`)"

  @spec attempt(map()) :: Phoenix.LiveView.Rendered.t()
  def attempt(assigns) do
    ~H"""
    <div
      class="rounded-xl border border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-900"
      data-testid={"stage-run-#{run_ref(@run)}"}
    >
      <div class="flex flex-wrap items-center justify-between gap-2 border-b border-gray-100 px-4 py-2 text-xs text-gray-500 dark:border-gray-800 dark:text-gray-400">
        <span>
          <span :if={@many}>
            Tentativa {@run.attempt}{if @run.requeue > 0, do: " · de novo (#{@run.requeue})"} ·
          </span>
          <.stage_run_status run={@run} data-testid={"stage-run-status-#{run_ref(@run)}"} />
          <.stage_run_session run={@run} />
        </span>
        <span :if={@run.job} class="flex items-center gap-3">
          <span
            :if={@spent}
            class="text-primary-700 dark:text-primary-300"
            data-testid={"stage-run-spent-#{run_ref(@run)}"}
          >
            até agora {format_cost(@spent.cost_usd)} · {short_number(@spent.tokens)} tokens
          </span>
          <span>{format_duration(@run.job.duration_ms)}</span>
          <span>{format_cost(@run.job.cost_usd)}</span>
          <span
            :if={Job.tokens(@run.job) > 0}
            data-testid={"stage-run-tokens-#{run_ref(@run)}"}
          >
            {short_number(Job.tokens(@run.job))} tokens · {format_percent(Job.cache_hit(@run.job))} do cache
          </span>
          <.link
            navigate={~p"/w/#{@workspace_slug}/jobs/#{@run.job.id}"}
            class="text-primary-600 hover:underline dark:text-primary-400"
            data-testid={"stage-run-audit-#{run_ref(@run)}"}
          >
            Execução e auditoria
          </.link>
        </span>
      </div>

      <div class="space-y-3 px-4 py-3">
        <p
          :if={@run.error && @run.status == :lost}
          class="text-sm text-warning-700 dark:text-warning-400"
          data-testid={"stage-run-lost-#{run_ref(@run)}"}
        >
          {@run.error}
        </p>
        <p
          :if={@run.error && @run.status != :lost}
          class="text-sm text-danger-700 dark:text-danger-400"
        >
          {@run.error}
        </p>

        <%!-- An ended attempt with an artifact leads with it; how it got
             there (summary, gates, commit, files, steps) is folded below. --%>
        <%= if artifact_first?(@run, @live) do %>
          <.artifact run={@run} raw_artifact={@raw_artifact} target={@target} />
          <.run_files run={@run} files={@files} workspace_slug={@workspace_slug} />

          <details
            id={"stage-run-details-#{@run.id}"}
            open={details_open?(@run)}
            phx-mounted={JS.ignore_attributes(["open"])}
            class="group rounded-lg border border-gray-200 dark:border-gray-800"
            data-testid={"stage-run-details-#{run_ref(@run)}"}
          >
            <summary
              class="flex cursor-pointer list-none flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2 text-sm text-gray-700 dark:text-gray-300"
              data-testid={"stage-run-details-toggle-#{run_ref(@run)}"}
            >
              <.icon
                name="hero-chevron-right"
                class="size-4 transition-transform group-open:rotate-90"
              />
              <span class="font-medium">Detalhes da etapa</span>
              <span
                :for={part <- details_summary(@run)}
                class="text-xs text-gray-500 dark:text-gray-400"
              >
                · {part}
              </span>
            </summary>
            <div class="space-y-3 border-t border-gray-200 px-3 py-3 dark:border-gray-800">
              <.run_details run={@run} />
              <.run_steps
                :if={@run.job}
                run={@run}
                steps={@steps}
                steps_filter={@steps_filter}
                target={@target}
              />
            </div>
          </details>
        <% else %>
          <.run_details run={@run} />
          <.artifact :if={@run.artifact} run={@run} raw_artifact={@raw_artifact} target={@target} />
          <.run_files run={@run} files={@files} workspace_slug={@workspace_slug} />

          <div :if={@live}>
            <p class="mb-3 text-xs font-medium uppercase tracking-wide text-info-600 dark:text-info-400">
              Ao vivo
            </p>
            <ol id="task-events" phx-update="stream" class="space-y-3" data-testid="task-events">
              <.timeline_segment
                :for={{id, segment} <- @streams.timeline}
                id={id}
                timeline="task-events"
                segment={segment}
              />
            </ol>
            <.typing :if={@typing} text={@typing} />
          </div>

          <.run_steps
            :if={@run.job && !@live}
            run={@run}
            steps={@steps}
            steps_filter={@steps_filter}
            target={@target}
          />
        <% end %>
      </div>
    </div>
    """
  end

  @doc "How many attempts the runs are: a run again after its runner lost it is the same attempt."
  @spec attempts([StageRun.t()]) :: non_neg_integer()
  def attempts(runs), do: runs |> Enum.uniq_by(& &1.attempt) |> length()

  # What tells an attempt apart in the test ids and DOM ids: its stage and
  # attempt, and how many times it ran again after its runner lost it.
  @spec run_ref(StageRun.t()) :: String.t()
  def run_ref(%StageRun{requeue: requeue} = run) when requeue > 0,
    do: "#{run.key}-#{run.attempt}-r#{requeue}"

  def run_ref(%StageRun{} = run), do: "#{run.key}-#{run.attempt}"

  attr :run, StageRun, required: true

  # How an attempt went: its environment, files, feedback, answers, summary,
  # result, commit and gates.
  @spec run_details(map()) :: Phoenix.LiveView.Rendered.t()
  def run_details(assigns) do
    ~H"""
    <.setup_report
      :if={@run.job && @run.job.setup}
      setup={@run.job.setup}
      data-testid={"stage-run-setup-#{run_ref(@run)}"}
    />

    <.changes_report
      :if={@run.job && @run.job.changes}
      changes={@run.job.changes}
      id={run_ref(@run)}
    />

    <details
      :if={@run.feedback}
      class="rounded-lg bg-warning-50 px-3 py-2 text-sm dark:bg-warning-950/30"
      data-testid={"stage-run-feedback-#{run_ref(@run)}"}
    >
      <summary class="cursor-pointer text-warning-800 dark:text-warning-300">
        Feedback da tentativa anterior
      </summary>
      <div
        id={"feedback-#{@run.id}"}
        phx-hook="Highlight"
        class="prose prose-sm mt-2 max-h-80 max-w-none overflow-auto dark:prose-invert"
      >
        {Markdown.to_html(@run.feedback)}
      </div>
    </details>

    <div
      :if={@run.answers}
      class="text-sm"
      data-testid={"stage-run-answers-#{run_ref(@run)}"}
    >
      <span class="font-medium text-gray-900 dark:text-white">Respostas da pessoa:</span>
      <.answer_list answers={@run.answers} class="mt-1 space-y-1 text-sm" />
    </div>

    <div
      :if={@run.instructions}
      class={[
        "text-sm text-gray-600 dark:text-gray-300",
        "prose prose-sm max-w-none dark:prose-invert"
      ]}
    >
      <span class="font-medium">Instruções:</span> {Markdown.inline_html(@run.instructions)}
    </div>

    <div
      :if={@run.summary}
      class={["text-sm text-gray-900 dark:text-white", "prose prose-sm max-w-none dark:prose-invert"]}
      data-testid={"stage-run-summary-#{run_ref(@run)}"}
    >
      {Markdown.inline_html(@run.summary)}
    </div>

    <details
      :if={@run.structured_output not in [nil, %{}]}
      id={"stage-run-output-#{@run.id}"}
      phx-mounted={JS.ignore_attributes(["open"])}
      class="text-sm"
      data-testid={"stage-run-output-#{run_ref(@run)}"}
    >
      <summary class="cursor-pointer text-gray-600 hover:text-gray-900 dark:text-gray-300 dark:hover:text-white">
        Resposta completa do agente
      </summary>
      <.agent_output
        id={"stage-run-output-body-#{@run.id}"}
        text={Jason.encode!(@run.structured_output)}
        class="mt-2 rounded-lg bg-gray-50 px-4 py-3 dark:bg-gray-950"
      />
    </details>

    <.agent_output
      :if={plain_result?(@run)}
      id={"result-#{@run.id}"}
      text={@run.job.result}
      class="max-h-[32rem] overflow-auto rounded-lg bg-gray-50 px-4 py-3 dark:bg-gray-950"
      data-testid={"stage-run-result-#{run_ref(@run)}"}
    />

    <p
      :if={@run.job && @run.job.delivery && @run.job.delivery["commit"]}
      class="text-xs text-gray-500 dark:text-gray-400"
      data-testid={"stage-run-commit-#{run_ref(@run)}"}
    >
      <.icon name="hero-check-badge" class="size-4 text-success-600" /> Commit
      <span class="font-mono">{String.slice(@run.job.delivery["commit"], 0, 7)}</span>
      <span :if={@run.job.delivery["pushed"]}>· enviado</span>
    </p>
    <p
      :if={@run.job && @run.job.delivery && @run.job.delivery["error"]}
      class="text-xs text-danger-700 dark:text-danger-400"
    >
      A entrega falhou: {@run.job.delivery["error"]}
    </p>

    <.gate_results
      :if={@run.job && @run.job.gates not in [nil, []]}
      gates={@run.job.gates}
      id={run_ref(@run)}
    />
    """
  end

  attr :run, StageRun, required: true
  attr :files, :list, required: true
  attr :workspace_slug, :string, required: true

  # The files the attempt's job sent, beside its artifact, and how many did not
  # arrive.
  @spec run_files(map()) :: Phoenix.LiveView.Rendered.t()
  def run_files(assigns) do
    assigns = assign(assigns, failed: (assigns.run.job && assigns.run.job.files_failed) || 0)

    ~H"""
    <div
      :if={@files != [] or @failed > 0}
      class="space-y-2"
      data-testid={"stage-run-files-#{@run.key}-#{@run.attempt}"}
    >
      <p class="text-xs font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400">
        Arquivos
      </p>
      <.files_failed
        :if={@failed > 0}
        count={@failed}
        data-testid={"stage-run-files-failed-#{@run.key}-#{@run.attempt}"}
      />
      <.files
        :if={@files != []}
        files={@files}
        workspace_slug={@workspace_slug}
        testid="stage-run-file"
        key={"#{@run.key}-#{@run.attempt}"}
      />
    </div>
    """
  end

  attr :run, StageRun, required: true
  attr :raw_artifact, :boolean, required: true
  attr :target, :any, default: nil

  # What the stage produced, rendered or as the text the agent wrote.
  @spec artifact(map()) :: Phoenix.LiveView.Rendered.t()
  def artifact(assigns) do
    ~H"""
    <div>
      <div class="mb-1 flex items-center justify-between">
        <p class="text-xs font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400">
          Artefato
        </p>
        <button
          type="button"
          phx-click="toggle_artifact"
          phx-value-run={@run.id}
          phx-target={@target}
          class="text-xs font-medium text-gray-500 hover:text-gray-900 dark:text-gray-400 dark:hover:text-white"
          data-testid={"stage-run-artifact-toggle-#{run_ref(@run)}"}
        >
          {if @raw_artifact, do: "Ver renderizado", else: "Ver texto"}
        </button>
      </div>
      <div
        :if={!@raw_artifact}
        id={"artifact-#{@run.id}"}
        phx-hook="Highlight"
        class="prose prose-sm max-h-[40rem] max-w-none overflow-auto prose-h1:text-xl prose-h2:text-lg prose-h3:text-base rounded-lg bg-gray-50 px-4 py-3 dark:prose-invert dark:bg-gray-950"
        data-testid={"stage-run-artifact-#{run_ref(@run)}"}
      >
        {Markdown.to_html(@run.artifact)}
      </div>
      <pre
        :if={@raw_artifact}
        class="max-h-[40rem] overflow-auto whitespace-pre-wrap break-words rounded-lg bg-gray-50 px-4 py-3 font-mono text-sm text-gray-800 dark:bg-gray-950 dark:text-gray-100"
        data-testid={"stage-run-artifact-raw-#{run_ref(@run)}"}
      >{@run.artifact}</pre>
    </div>
    """
  end

  attr :run, StageRun, required: true
  attr :steps, :list, default: nil
  attr :steps_filter, :string, default: "all"
  attr :target, :any, default: nil

  # The agent's steps, read when asked for and filtered by kind.
  @spec run_steps(map()) :: Phoenix.LiveView.Rendered.t()
  def run_steps(assigns) do
    ~H"""
    <div>
      <button
        type="button"
        phx-click="toggle_steps"
        phx-value-job={@run.job.id}
        phx-target={@target}
        class="text-sm font-medium text-gray-600 hover:text-gray-900 dark:text-gray-300 dark:hover:text-white"
        data-testid={"stage-run-steps-toggle-#{run_ref(@run)}"}
      >
        <.icon
          name={if @steps, do: "hero-chevron-down", else: "hero-chevron-right"}
          class="size-4"
        /> Passo a passo do agente
      </button>
      <div :if={@steps} class="mt-2 flex flex-wrap gap-1">
        <.button
          :for={
            {filter, label} <- [
              {"all", "Tudo"},
              {"agent", "Agente"},
              {"tools", "Ferramentas"},
              {"thinking", "Raciocínio"},
              {"errors", "Erros"}
            ]
          }
          size="xs"
          variant={if @steps_filter == filter, do: "solid", else: "ghost"}
          color="gray"
          phx-click="filter_steps"
          phx-value-job={@run.job.id}
          phx-target={@target}
          phx-value-filter={filter}
          data-testid={"stage-run-steps-filter-#{run_ref(@run)}-#{filter}"}
        >
          {label}
        </.button>
      </div>
      <.steps
        :if={@steps}
        items={timeline_items(@steps, @steps_filter)}
        id={run_ref(@run)}
      />
    </div>
    """
  end

  defp artifact_first?(%StageRun{artifact: artifact, status: status}, live),
    do: is_binary(artifact) and status != :running and not live

  # Opened already when something went wrong in it: a gate that failed, a
  # delivery that did not happen.
  defp details_open?(%StageRun{job: %Job{} = job}) do
    Enum.any?(job.gates || [], &(&1["passed"] == false)) or
      match?(%{"error" => error} when is_binary(error), job.delivery)
  end

  defp details_open?(_run), do: false

  # What the folded details hold, in a line: gates met, files, commit.
  defp details_summary(%StageRun{job: %Job{} = job}) do
    gates = job.gates || []
    files = (job.changes || %{})["files"] || []
    commit = (job.delivery || %{})["commit"]

    [
      gates != [] &&
        "gates #{Enum.count(gates, & &1["passed"])}/#{length(gates)}",
      files != [] && count_label(length(files), "arquivo", "arquivos"),
      is_binary(commit) && "commit #{String.slice(commit, 0, 7)}"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp details_summary(_run), do: []

  attr :gates, :list, required: true
  attr :id, :string, required: true

  # The stage's gate commands, each met or not, its output folded.
  @spec gate_results(map()) :: Phoenix.LiveView.Rendered.t()
  def gate_results(assigns) do
    ~H"""
    <div data-testid={"stage-run-gates-#{@id}"}>
      <p class="mb-1 text-xs font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400">
        Gates
      </p>
      <ul class="space-y-1">
        <li
          :for={{gate, index} <- Enum.with_index(@gates)}
          data-testid={"stage-run-gate-#{@id}-#{index}"}
          data-passed={to_string(gate["passed"])}
        >
          <details class="text-sm">
            <summary class="flex cursor-pointer items-center gap-2">
              <.icon
                name={if gate["passed"], do: "hero-check-circle", else: "hero-x-circle"}
                class={[
                  "size-4 shrink-0",
                  if(gate["passed"],
                    do: "text-success-600 dark:text-success-400",
                    else: "text-danger-600 dark:text-danger-400"
                  )
                ]}
              />
              <code
                :if={!gate["platform"]}
                class="break-all text-xs text-gray-800 dark:text-gray-200"
              >
                {gate["command"]}
              </code>
              <span :if={gate["platform"]} class="text-xs text-gray-800 dark:text-gray-200">
                <.badge color="info" size="sm" data-testid={"stage-run-gate-platform-#{@id}-#{index}"}>
                  plataforma
                </.badge>
                {String.replace_prefix(gate["command"] || "", "plataforma: ", "")}
              </span>
              <span :if={!gate["platform"]} class="shrink-0 text-xs text-gray-500 dark:text-gray-400">
                {if gate["expect"] == "fail", do: "deve falhar", else: "deve passar"} · código {gate[
                  "exit_code"
                ]}
              </span>
            </summary>
            <pre
              :if={gate["output"] not in [nil, ""]}
              class="mt-1 max-h-64 overflow-auto whitespace-pre-wrap break-words rounded-lg bg-gray-50 px-3 py-2 font-mono text-xs text-gray-800 dark:bg-gray-950 dark:text-gray-100"
            >{gate["output"]}</pre>
          </details>
        </li>
      </ul>
    </div>
    """
  end

  attr :setup, :map, required: true
  attr :rest, :global

  # How the runner prepared the task's worktree, on the attempt that created it.
  @spec setup_report(map()) :: Phoenix.LiveView.Rendered.t()
  def setup_report(assigns) do
    ~H"""
    <details class="rounded-lg bg-gray-50 px-3 py-2 text-sm dark:bg-gray-950" {@rest}>
      <summary class="cursor-pointer text-gray-700 dark:text-gray-300">
        <.icon name="hero-wrench-screwdriver" class="size-4" />
        Ambiente preparado em {format_duration(@setup["duration_ms"])}
        <span :if={@setup["copied"] != []} class="text-gray-500 dark:text-gray-400">
          · copiado: {Enum.join(@setup["copied"] || [], ", ")}
        </span>
        <span :if={@setup["command"]} class="text-gray-500 dark:text-gray-400">
          · <code>{@setup["command"]}</code> (código {@setup["exit_code"]})
        </span>
      </summary>
      <pre
        :if={@setup["output"] not in [nil, ""]}
        class="mt-2 max-h-80 overflow-auto whitespace-pre-wrap break-words font-mono text-xs text-gray-700 dark:text-gray-300"
      >{@setup["output"]}</pre>
    </details>
    """
  end

  # The agent's final answer, for a stage without structured output; with
  # one, the summary above already says it and the raw JSON would repeat it.
  defp plain_result?(%StageRun{status: status, structured_output: nil, job: %{result: result}})
       when status != :running and is_binary(result),
       do: true

  defp plain_result?(_run), do: false
end
