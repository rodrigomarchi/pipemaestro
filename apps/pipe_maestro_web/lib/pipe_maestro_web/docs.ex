defmodule PipeMaestroWeb.Docs do
  @moduledoc """
  The public documentation: sections of pages, each page a Markdown file in
  `priv/docs/<slug>.md`, read and rendered when this module compiles.

  `PipeMaestroWeb.Docs.Blocks` turns each file into the blocks of its page.
  """

  alias PipeMaestroWeb.Docs.Blocks

  @type page :: %{
          slug: String.t(),
          title: String.t(),
          description: String.t(),
          section: String.t(),
          blocks: [Blocks.t()]
        }

  @type section :: %{
          key: String.t(),
          title: String.t(),
          icon: String.t(),
          intro: String.t(),
          pages: [page()]
        }

  @sections [
    %{
      key: "comecar",
      title: "Primeiros passos",
      icon: "hero-rocket-launch",
      intro: "Do cadastro ao primeiro Pull Request, e o runner na sua máquina.",
      pages: [
        {"primeiros-passos", "Do zero ao primeiro PR",
         "Conecte uma máquina, cadastre o projeto, escolha um pipeline e crie a primeira tarefa."},
        {"runner", "O runner na sua máquina",
         "Baixar, entrar, ligar, deixar como serviço e diagnosticar o executável que roda o agente."}
      ]
    },
    %{
      key: "exemplos",
      title: "Exemplos do dia a dia",
      icon: "hero-light-bulb",
      intro:
        "Situações comuns de um time, do pedido ao PR, com o pipeline que serve para cada uma.",
      pages: [
        {"corrigir-um-bug", "Corrigir um bug com teste de reprodução",
         "Um bug relatado pelo suporte vira um teste que falha, a correção e um PR."},
        {"issue-vira-pr", "Uma issue do GitHub vira PR sozinha",
         "Uma label na issue dispara a tarefa; a issue mostra o andamento e recebe comandos."},
        {"nova-funcionalidade", "Uma funcionalidade pequena, com revisões",
         "Especificação, plano, implementação e as revisões de código e de segurança em paralelo."},
        {"atualizar-dependencia", "Atualizar uma dependência",
         "O changelog lido, a atualização feita e o risco resumido para quem revisa."},
        {"investigar-producao", "Investigar um problema de produção",
         "Hipóteses com evidências e a correção proposta, sem mudar nada no código."},
        {"revisar-e-refatorar", "Revisar um branch e refatorar com segurança",
         "Uma revisão de código que não altera nada, e uma refatoração em passos com a suíte verde."}
      ]
    },
    %{
      key: "conceitos",
      title: "Conceitos",
      icon: "hero-academic-cap",
      intro: "As peças da plataforma e como elas se encaixam.",
      pages: [
        {"tarefas-e-pipelines", "Tarefas, pipelines e etapas",
         "O que é cada peça, os gates que julgam uma etapa e como o trabalho vira PR."},
        {"decisoes", "Decisões: quando o agente para",
         "Por que uma tarefa pausa, as perguntas do agente e as formas de responder."},
        {"agente-ajudante", "O agente como ajudante",
         "Escrever a tarefa, propor o projeto e o pipeline, melhorar um pipeline e sugerir decisões."},
        {"acompanhar", "Acompanhar, auditar e medir",
         "Board, notificações, auditoria de cada execução, custo e a qualidade das entregas."}
      ]
    },
    %{
      key: "integracoes",
      title: "Integrações",
      icon: "hero-link",
      intro: "GitHub e Forgejo: issues que viram tarefas e PRs que se corrigem.",
      pages: [
        {"github-e-forgejo", "Conectar o GitHub ou o Forgejo",
         "Conexão, repositórios vinculados, gatilhos e o retorno que a issue recebe."},
        {"comandos", "Comandos na issue e no PR",
         "Seguir, refazer, responder, pausar, cancelar e corrigir sem sair do host git; merge automático."}
      ]
    },
    %{
      key: "seguranca",
      title: "Segurança e dúvidas",
      icon: "hero-shield-check",
      intro: "O que fica onde, quem pode o quê e as perguntas mais comuns.",
      pages: [
        {"seguranca", "Segurança: o seu código fica com você",
         "O que sai da sua máquina, o que fica no control plane e os papéis de cada pessoa."},
        {"perguntas-frequentes", "Perguntas frequentes",
         "Custo, modelos, limites, linguagens, várias máquinas e o que fazer quando algo para."}
      ]
    }
  ]

  @docs_dir Path.expand("../../priv/docs", __DIR__)
  sections =
    for section <- @sections do
      pages =
        for {slug, title, description} <- section.pages do
          path = Path.join(@docs_dir, "#{slug}.md")
          @external_resource path

          %{
            slug: slug,
            title: title,
            description: description,
            section: section.key,
            blocks: Blocks.render(File.read!(path), slug)
          }
        end

      %{section | pages: pages}
    end

  @compiled sections
  @pages Enum.flat_map(sections, & &1.pages)

  @doc "Every section, with its pages in reading order."
  @spec sections() :: [section()]
  def sections, do: @compiled

  @doc "Every page, in reading order."
  @spec pages() :: [page()]
  def pages, do: @pages

  @doc "The page `slug`."
  @spec fetch(String.t()) :: {:ok, page()} | :error
  def fetch(slug) do
    case Enum.find(@pages, &(&1.slug == slug)) do
      nil -> :error
      page -> {:ok, page}
    end
  end

  @doc "The section `key`."
  @spec section!(String.t()) :: section()
  def section!(key), do: Enum.find(@compiled, &(&1.key == key)) || raise(ArgumentError, key)

  @doc "The pages before and after `page`, in reading order (nil at the ends)."
  @spec neighbors(page()) :: {page() | nil, page() | nil}
  def neighbors(%{slug: slug}) do
    index = Enum.find_index(@pages, &(&1.slug == slug))
    previous = if index > 0, do: Enum.at(@pages, index - 1)
    {previous, Enum.at(@pages, index + 1)}
  end
end
