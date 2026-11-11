defmodule PipeMaestroWeb.LandingShots do
  @moduledoc """
  The screenshots of the platform the public pages show: the landing's hero
  board and one block of its product tour per screen, in the tour's order
  (`all/0`), the steps of its walkthrough from an empty workspace to the first
  task done, each with its screens (`walkthrough/0`), and the further screens
  only the documentation shows (`docs/0`). A documentation page places any of
  them by name (`fetch/1`).

  The files live in `priv/static/images/landing/`, `<name>.png` for the light
  theme and `<name>-dark.png` for the dark one, and are made by the e2e director
  (`make landing.shots`, `e2e/director/`), which frames every screen at the size
  declared here: the whole window, or a close-up (`kind: :detail`) of one part
  of it.
  """

  @type theme :: :light | :dark

  @type shot :: %{
          required(:name) => String.t(),
          required(:alt) => String.t(),
          required(:kind) => :screen | :detail,
          required(:width) => pos_integer(),
          required(:height) => pos_integer(),
          optional(:title) => String.t(),
          optional(:text) => String.t(),
          optional(:caption) => String.t()
        }

  @type step :: %{
          title: String.t(),
          text: String.t(),
          code: [String.t()],
          shots: [shot()]
        }

  # The director's viewport (1440x900) at device scale 2, and the box of its
  # close-ups (`DETAIL` in e2e/director/capture.ts, 960x450) at the same scale.
  @width 2880
  @height 1800
  @detail_width 1920
  @detail_height 900

  @walkthrough [
    %{
      title: "Conecte o runner",
      text:
        "Baixe o executável na máquina que tem o seu código e entre. O terminal mostra um código de oito letras: confirme-o no navegador e dê um nome à máquina.",
      code: [
        "pipemaestro login --url https://app.pipemaestro.dev",
        "pipemaestro start --root ~/src"
      ],
      shots: [
        %{
          name: "setup-runner",
          alt:
            "Página de conectar runner com o pedido de conexão encontrado e o nome macbook-marina preenchido"
        }
      ]
    },
    %{
      title: "Cadastre o projeto",
      text:
        "Escolha um dos diretórios que o runner oferece e diga como preparar, testar e checar o código. São esses comandos que decidem se uma etapa passou.",
      code: [],
      shots: [
        %{
          name: "setup-project",
          alt:
            "Formulário de novo projeto com o runner macbook-marina, o diretório loja-api e os comandos make deps, make test e make lint"
        }
      ]
    },
    %{
      title: "Escolha um pipeline",
      text:
        "Um clique cria os pipelines prontos: correção de bug, nova funcionalidade, refatoração, atualização de dependência e outros. Use como estão ou edite.",
      code: [],
      shots: [
        %{
          name: "setup-pipelines",
          alt: "Lista de pipelines do workspace com os pipelines padrão criados"
        }
      ]
    },
    %{
      title: "Ponha um gate",
      text:
        "No editor, a aba Verificação de uma etapa recebe os comandos que precisam passar. Com {{projeto.teste}}, a implementação só segue se os testes do projeto passarem.",
      code: [],
      shots: [
        %{
          name: "setup-gate",
          alt:
            "Editor do pipeline Correção de bug com a aba Verificação da etapa Implementação e o gate {{projeto.teste}}"
        }
      ]
    },
    %{
      title: "Veja o pipeline de ponta a ponta",
      text:
        "O diagrama mostra cada etapa na ordem, de onde a tarefa entra até a entrega. Recolha o menu para o diagrama ocupar a tela, ou abra-o para navegar.",
      code: [],
      shots: [
        %{
          name: "setup-pipeline",
          caption: "Menu recolhido",
          alt: "Diagrama do pipeline Correção de bug com o menu lateral recolhido"
        },
        %{
          name: "setup-pipeline-menu",
          caption: "Menu aberto",
          alt: "Diagrama do pipeline Correção de bug com o menu lateral aberto"
        }
      ]
    },
    %{
      title: "Abra uma etapa",
      text:
        "Clique numa etapa e a gaveta mostra o que ela pede ao agente e o que precisa passar para seguir.",
      code: [],
      shots: [
        %{
          name: "setup-pipeline-stage",
          alt: "Pipeline Correção de bug com a gaveta da etapa Implementação aberta"
        }
      ]
    },
    %{
      title: "Crie a primeira tarefa",
      text:
        "Escreva o pedido como escreveria para uma pessoa do time e escolha o pipeline e o projeto.",
      code: [],
      shots: [
        %{
          name: "first-task-new",
          alt:
            "Formulário de nova tarefa com o pedido sobre o arredondamento do cupom, o pipeline Correção de bug e o projeto Loja API"
        }
      ]
    },
    %{
      title: "Acompanhe ao vivo",
      text:
        "A tarefa percorre as etapas no runner. Abra a etapa que está rodando e veja o agente ler, buscar e executar, passo a passo.",
      code: [],
      shots: [
        %{
          name: "first-task-running",
          caption: "As etapas",
          alt: "Tarefa com a triagem concluída e a investigação em execução"
        },
        %{
          name: "first-task-stage",
          caption: "A etapa aberta",
          alt: "Gaveta da etapa Investigação aberta com os passos do agente ao vivo"
        }
      ]
    },
    %{
      title: "O gate barra o que não passa",
      text:
        "A primeira implementação não corrigiu o bug, embora o agente achasse que sim. O gate rodou make test, viu a falha, e a etapa tentou de novo.",
      code: [],
      shots: [
        %{
          name: "first-task-gate",
          kind: :detail,
          alt:
            "Verificação da primeira tentativa da Implementação com o gate make test reprovado e a saída do teste"
        }
      ]
    },
    %{
      title: "Tarefa concluída",
      text:
        "Cada etapa passou, a segunda implementação pelo gate. Com a entrega em pull request, o código chega como um PR pronto para a sua revisão.",
      code: [],
      shots: [
        %{
          name: "first-task-done",
          alt: "Tarefa concluída com todas as etapas aprovadas e duas tentativas na Implementação"
        }
      ]
    }
  ]

  @shots [
    %{
      name: "board",
      title: "Acompanhe ao vivo",
      text:
        "O board mostra cada tarefa no seu estado e o progresso do pipeline etapa por etapa: o que está rodando, o que espera uma decisão e o que já terminou.",
      alt:
        "Aba Tarefas do board do workspace Nimbus com duas tarefas em execução, uma aguardando decisão e duas concluídas"
    },
    %{
      name: "task",
      title: "Cada etapa à vista",
      text:
        "Abra uma etapa e veja o artefato que ela escreveu, os arquivos que mudou e o passo a passo do agente, com a saída de cada ferramenta.",
      alt:
        "Etapa de reprodução de uma tarefa, com o artefato, o passo a passo do agente e a saída de make test"
    },
    %{
      name: "decision",
      title: "Decida quando o agente para",
      text:
        "Quando falta uma decisão, a tarefa pausa e o agente pergunta, com as alternativas e a que ele recomenda. Você responde e ela segue.",
      alt:
        "Questionário de decisão com duas perguntas do agente e as opções recomendadas destacadas"
    },
    %{
      name: "audit",
      title: "Audite cada execução",
      text:
        "Sessão, modelo, para onde foi o tempo, tokens, cache e cada ferramenta usada: o registro de como o agente trabalhou.",
      alt:
        "Auditoria de uma execução com o tempo por categoria, os tokens e as ferramentas usadas"
    },
    %{
      name: "usage",
      title: "Controle o custo",
      text:
        "Custo, execuções, tempo de agente e tokens por dia, e o detalhe por pipeline, projeto, runner, pessoa e etapa.",
      alt:
        "Visão geral do uso com o custo, as execuções, o tempo de agente e os tokens da semana e o custo por dia"
    },
    %{
      name: "runners",
      title: "Roda na sua máquina",
      text:
        "O runner é um executável que se conecta para fora, no seu computador ou servidor. O código não sai de lá, e várias tarefas rodam em paralelo.",
      alt: "Lista de runners do workspace com o runner macbook-marina online e capacidade 4"
    }
  ]

  @docs_shots [
    %{
      name: "pipeline",
      title: "O pipeline, de cima a baixo",
      text: "Cada etapa na ordem, as revisões em paralelo lado a lado e onde uma pessoa decide.",
      alt:
        "Diagrama do pipeline Nova funcionalidade com as revisões de código e de segurança em paralelo"
    },
    %{
      name: "integrations",
      title: "Integrações com o host git",
      text:
        "Cada evento que o host git manda fica registrado, com o que a plataforma fez com ele.",
      alt:
        "Entregas da conexão Forgejo da Nimbus: a label da issue que criou a tarefa e o PR integrado"
    },
    %{
      name: "notifications",
      title: "Notificações",
      text: "O sino mostra o que roda agora e avisa quando uma tarefa pausa ou termina.",
      alt: "Painel de notificações aberto com tarefas em andamento e uma que espera decisão"
    },
    %{
      name: "quality",
      title: "Qualidade das entregas",
      text:
        "Quantos PRs foram aceitos sem mudança, com mudança ou fechados, e o retrabalho por etapa.",
      alt: "Aba Qualidade do Uso com os PRs entregues por pipeline e o retrabalho por etapa"
    }
  ]

  @doc "Every screenshot of the landing's tour, in the order it shows them."
  @spec all() :: [shot()]
  def all, do: Enum.map(@shots, &sized/1)

  @doc "The screenshots only the documentation shows."
  @spec docs() :: [shot()]
  def docs, do: Enum.map(@docs_shots, &sized/1)

  @doc """
  The landing's walkthrough, from an empty workspace to the first task done:
  each step with its copy, the commands it runs (`code`, often none) and its
  screens, in order.
  """
  @spec walkthrough() :: [step()]
  def walkthrough do
    Enum.map(@walkthrough, fn step -> %{step | shots: Enum.map(step.shots, &sized/1)} end)
  end

  @doc "Every screenshot: the tour's, the walkthrough's and the documentation's."
  @spec every() :: [shot()]
  def every, do: all() ++ Enum.flat_map(walkthrough(), & &1.shots) ++ docs()

  @doc "The screenshot named `name`, of the tour, the walkthrough or the documentation."
  @spec fetch(String.t()) :: {:ok, shot()} | :error
  def fetch(name) do
    case Enum.find(every(), &(&1.name == name)) do
      nil -> :error
      shot -> {:ok, shot}
    end
  end

  defp sized(%{kind: :detail} = shot),
    do: Map.merge(shot, %{width: @detail_width, height: @detail_height})

  defp sized(shot), do: Map.merge(shot, %{kind: :screen, width: @width, height: @height})

  @doc "The static path of the screenshot `name` in `theme`."
  @spec path(String.t(), theme()) :: String.t()
  def path(name, :light), do: "/images/landing/#{name}.png"
  def path(name, :dark), do: "/images/landing/#{name}-dark.png"
end
