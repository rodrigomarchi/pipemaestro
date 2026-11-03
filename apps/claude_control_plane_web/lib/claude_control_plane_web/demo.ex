defmodule ClaudeControlPlaneWeb.Demo do
  @moduledoc """
  Static sample data for the screens that exist before the domain does.

  Every function here stands in for a context of `ClaudeControlPlane` that is
  not written yet (tasks, pipeline runs, decisions, runners). LiveViews read
  from this module only; when a context lands, its screen switches to it and
  the matching function here is deleted.
  """

  @type stage :: %{id: atom(), name: String.t(), icon: String.t()}

  @type task :: %{
          id: String.t(),
          issue: pos_integer(),
          title: String.t(),
          repo: String.t(),
          kind: :bug | :feature | :refactor | :chore,
          stage: atom(),
          status: :running | :waiting_decision | :queued | :ready,
          runner: String.t() | nil,
          elapsed: String.t() | nil,
          tokens: String.t() | nil,
          retries: non_neg_integer(),
          author: String.t()
        }

  @type decision :: %{
          id: String.t(),
          task_id: String.t(),
          issue: pos_integer(),
          title: String.t(),
          question: String.t(),
          stage: String.t(),
          due: String.t(),
          options: [String.t()]
        }

  @type runner :: %{
          name: String.t(),
          status: :online | :busy | :offline,
          labels: [String.t()],
          load: non_neg_integer(),
          capacity: pos_integer(),
          version: String.t(),
          last_seen: String.t()
        }

  @type activity :: %{
          title: String.t(),
          description: String.t(),
          time: String.t(),
          icon: String.t(),
          color: String.t()
        }

  @type stat :: %{
          label: String.t(),
          value: String.t(),
          delta: String.t(),
          icon: String.t(),
          trend: [number()]
        }

  @doc "The stages of the reference bug-fix pipeline, in order."
  @spec stages() :: [stage()]
  def stages do
    [
      %{id: :triage, name: "Triagem", icon: "hero-funnel"},
      %{id: :investigation, name: "Investigação", icon: "hero-magnifying-glass"},
      %{id: :reproduction, name: "Reprodução", icon: "hero-beaker"},
      %{id: :implementation, name: "Implementação", icon: "hero-code-bracket"},
      %{id: :audit, name: "Auditoria", icon: "hero-shield-check"},
      %{id: :pr_ready, name: "PR pronto", icon: "hero-check-badge"}
    ]
  end

  @doc "Tasks currently moving through a pipeline."
  @spec tasks() :: [task()]
  def tasks do
    [
      task("t-101", 482, "Checkout falha com cupom expirado", "acme/storefront", :bug, :triage,
        status: :running,
        runner: "runner-sp-01",
        elapsed: "1m 12s",
        tokens: "8,4k"
      ),
      task(
        "t-102",
        479,
        "Exportar relatório de faturas em CSV",
        "acme/billing",
        :feature,
        :triage,
        status: :queued
      ),
      task("t-103", 471, "Timeout no webhook do Stripe", "acme/billing", :bug, :investigation,
        status: :running,
        runner: "runner-sp-02",
        elapsed: "6m 40s",
        tokens: "41k"
      ),
      task("t-104", 466, "N+1 na listagem de pedidos", "acme/storefront", :bug, :reproduction,
        status: :waiting_decision,
        runner: "runner-sp-01",
        elapsed: "14m 05s",
        tokens: "96k",
        retries: 2
      ),
      task(
        "t-105",
        460,
        "Migrar envio de e-mail para Oban",
        "acme/notifications",
        :refactor,
        :implementation,
        status: :running,
        runner: "runner-dev-ana",
        elapsed: "22m 31s",
        tokens: "184k"
      ),
      task(
        "t-106",
        455,
        "Paginação por cursor na API de clientes",
        "acme/api",
        :feature,
        :implementation,
        status: :running,
        runner: "runner-sp-02",
        elapsed: "31m 02s",
        tokens: "212k",
        retries: 1
      ),
      task("t-107", 449, "Atualizar Phoenix para 1.8", "acme/api", :chore, :audit,
        status: :running,
        runner: "runner-sp-01",
        elapsed: "38m 50s",
        tokens: "257k"
      ),
      task(
        "t-108",
        441,
        "Corrigir fuso horário em agendamentos",
        "acme/scheduler",
        :bug,
        :pr_ready,
        status: :ready,
        elapsed: "41m 17s",
        tokens: "198k"
      ),
      task(
        "t-109",
        437,
        "Remover feature flag de checkout novo",
        "acme/storefront",
        :chore,
        :pr_ready,
        status: :ready,
        elapsed: "19m 44s",
        tokens: "77k"
      )
    ]
  end

  @doc "Tasks grouped by stage id, every stage present even when empty."
  @spec tasks_by_stage() :: %{atom() => [task()]}
  def tasks_by_stage do
    empty = Map.new(stages(), &{&1.id, []})
    Map.merge(empty, Enum.group_by(tasks(), & &1.stage))
  end

  @doc "Human decisions the pipeline is paused on."
  @spec decisions() :: [decision()]
  def decisions do
    [
      %{
        id: "d-31",
        task_id: "t-104",
        issue: 466,
        title: "N+1 na listagem de pedidos",
        question:
          "O teste de reprodução passa antes do fix em 2 de 3 execuções. Seguir com o teste instável ou reescrever com dados fixos?",
        stage: "Reprodução",
        due: "em 3h",
        options: ["Reescrever teste", "Seguir assim", "Abortar"]
      },
      %{
        id: "d-30",
        task_id: "t-106",
        issue: 455,
        title: "Paginação por cursor na API de clientes",
        question:
          "O plano altera o contrato público de /v1/customers. Aprovar a quebra de compatibilidade?",
        stage: "Implementação",
        due: "amanhã",
        options: ["Aprovar", "Ajustar plano", "Abortar"]
      }
    ]
  end

  @doc "Runners registered by the organization."
  @spec runners() :: [runner()]
  def runners do
    [
      %{
        name: "runner-sp-01",
        status: :busy,
        labels: ["linux", "elixir", "node"],
        load: 3,
        capacity: 4,
        version: "0.1.0",
        last_seen: "agora"
      },
      %{
        name: "runner-sp-02",
        status: :busy,
        labels: ["linux", "elixir", "postgres"],
        load: 2,
        capacity: 4,
        version: "0.1.0",
        last_seen: "agora"
      },
      %{
        name: "runner-dev-ana",
        status: :online,
        labels: ["macos", "elixir"],
        load: 1,
        capacity: 2,
        version: "0.1.0",
        last_seen: "há 4s"
      },
      %{
        name: "runner-gpu-01",
        status: :offline,
        labels: ["linux", "python", "cuda"],
        load: 0,
        capacity: 2,
        version: "0.0.9",
        last_seen: "há 2h"
      }
    ]
  end

  @doc "The latest pipeline events across the organization, newest first."
  @spec activity() :: [activity()]
  def activity do
    [
      %{
        title: "PR #1290 pronto para revisão",
        description: "acme/scheduler · Corrigir fuso horário em agendamentos",
        time: "há 2 min",
        icon: "hero-check-badge",
        color: "success"
      },
      %{
        title: "Decisão pendente criada",
        description: "acme/storefront #466 · teste de reprodução instável",
        time: "há 9 min",
        icon: "hero-hand-raised",
        color: "warning"
      },
      %{
        title: "Gate de testes falhou (tentativa 1/3)",
        description: "acme/api #455 · 2 testes quebrados em customers_controller_test",
        time: "há 17 min",
        icon: "hero-x-circle",
        color: "danger"
      },
      %{
        title: "Auditoria iniciada",
        description: "acme/api #449 · contexto novo, sem acesso à implementação",
        time: "há 21 min",
        icon: "hero-shield-check",
        color: "info"
      },
      %{
        title: "Executor runner-gpu-01 offline",
        description: "Lease reatribuído para runner-sp-02",
        time: "há 2 h",
        icon: "hero-signal-slash",
        color: "gray"
      }
    ]
  end

  @doc "Headline numbers for the board, each with a short trend."
  @spec stats() :: [stat()]
  def stats do
    [
      %{
        label: "Tarefas em andamento",
        value: "7",
        delta: "+2 hoje",
        icon: "hero-bolt",
        trend: [3, 4, 4, 5, 4, 6, 7]
      },
      %{
        label: "PRs prontos (7 dias)",
        value: "23",
        delta: "+18%",
        icon: "hero-arrow-up-tray",
        trend: [2, 3, 5, 3, 4, 3, 3]
      },
      %{
        label: "Tempo médio até PR",
        value: "38 min",
        delta: "−6 min",
        icon: "hero-clock",
        trend: [52, 49, 47, 44, 42, 40, 38]
      },
      %{
        label: "Tokens hoje",
        value: "1,2M",
        delta: "62% do orçamento",
        icon: "hero-cpu-chip",
        trend: [0.2, 0.3, 0.5, 0.6, 0.8, 1.0, 1.2]
      }
    ]
  end

  defp task(id, issue, title, repo, kind, stage, opts) do
    %{
      id: id,
      issue: issue,
      title: title,
      repo: repo,
      kind: kind,
      stage: stage,
      status: Keyword.fetch!(opts, :status),
      runner: Keyword.get(opts, :runner),
      elapsed: Keyword.get(opts, :elapsed),
      tokens: Keyword.get(opts, :tokens),
      retries: Keyword.get(opts, :retries, 0),
      author: "ana"
    }
  end
end
