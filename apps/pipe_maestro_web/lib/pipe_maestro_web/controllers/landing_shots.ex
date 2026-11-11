defmodule PipeMaestroWeb.LandingShots do
  @moduledoc """
  The screenshots of the platform the public pages show: the landing's hero
  board and one block of its product tour per screen, in the tour's order
  (`all/0`), and the further screens only the documentation shows (`docs/0`).
  A documentation page places any of them by name (`fetch/1`).

  The files live in `priv/static/images/landing/`, `<name>.png` for the light
  theme and `<name>-dark.png` for the dark one, and are made by the e2e director
  (`make landing.shots`, `e2e/director/`), which frames every screen at the size
  declared here.
  """

  @type theme :: :light | :dark

  @type shot :: %{
          name: String.t(),
          title: String.t(),
          text: String.t(),
          alt: String.t(),
          width: pos_integer(),
          height: pos_integer()
        }

  # The director's viewport (1440x900) at device scale 2.
  @width 2880
  @height 1800

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

  @doc "The screenshot named `name`, of the tour or of the documentation."
  @spec fetch(String.t()) :: {:ok, shot()} | :error
  def fetch(name) do
    case Enum.find(all() ++ docs(), &(&1.name == name)) do
      nil -> :error
      shot -> {:ok, shot}
    end
  end

  defp sized(shot), do: Map.merge(shot, %{width: @width, height: @height})

  @doc "The static path of the screenshot `name` in `theme`."
  @spec path(String.t(), theme()) :: String.t()
  def path(name, :light), do: "/images/landing/#{name}.png"
  def path(name, :dark), do: "/images/landing/#{name}-dark.png"
end
