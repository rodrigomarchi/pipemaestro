defmodule PipeMaestroWeb.LandingShots do
  @moduledoc """
  The screenshots of the platform the landing page shows: the hero's board and
  one block of the product tour per screen, in the tour's order.

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
        "O board mostra cada tarefa na sua etapa: o que está rodando, o que espera uma decisão e o que já terminou, com o custo do período e o runner de cada uma.",
      alt:
        "Board do workspace Nimbus com tarefas em execução, uma aguardando decisão e duas concluídas"
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
        "Custo, execuções, tempo de agente e tokens por dia, por origem, por pipeline, por runner, por pessoa e por etapa.",
      alt:
        "Página de uso e limites com o custo da semana e a divisão por pipeline, runner e pessoa"
    },
    %{
      name: "runners",
      title: "Roda na sua máquina",
      text:
        "O runner é um executável que se conecta para fora, no seu computador ou servidor. O código não sai de lá, e várias tarefas rodam em paralelo.",
      alt: "Lista de runners do workspace com o runner macbook-marina online e capacidade 4"
    }
  ]

  @doc "Every screenshot, in the order the tour shows them."
  @spec all() :: [shot()]
  def all, do: Enum.map(@shots, &Map.merge(&1, %{width: @width, height: @height}))

  @doc "The static path of the screenshot `name` in `theme`."
  @spec path(String.t(), theme()) :: String.t()
  def path(name, :light), do: "/images/landing/#{name}.png"
  def path(name, :dark), do: "/images/landing/#{name}-dark.png"
end
