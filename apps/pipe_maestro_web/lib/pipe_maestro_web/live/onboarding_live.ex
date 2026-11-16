defmodule PipeMaestroWeb.OnboardingLive do
  @moduledoc """
  The getting-started lesson of a new Free beta workspace (ADR 0058): three
  screens that show how to connect a runner, add a project and pick a
  pipeline, with the texts, commands and screenshots of the landing's
  walkthrough. It sets nothing up. Skipping it, or leaving it at the end,
  ends it for good (`PipeMaestro.Onboarding.dismiss/1`); the board sends an
  admin here while it is pending.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.PageHTML, only: [landing_shot: 1, command_block: 1]

  alias PipeMaestro.Onboarding
  alias PipeMaestroWeb.LandingShots

  @steps 3

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Primeiros passos",
       steps: Enum.take(LandingShots.walkthrough(), @steps)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    step =
      case Integer.parse(params["step"] || "") do
        {n, ""} when n in 1..@steps -> n
        _ -> 1
      end

    {:noreply, assign(socket, step: step)}
  end

  @impl true
  def handle_event("leave", %{"to" => to}, socket) do
    scope = socket.assigns.current_scope
    :ok = Onboarding.dismiss(scope)

    path =
      case to do
        "runners" -> ~p"/w/#{scope.workspace.slug}/runners"
        _board -> ~p"/w/#{scope.workspace.slug}"
      end

    {:noreply, push_navigate(socket, to: path)}
  end

  defp step_path(scope, step), do: ~p"/w/#{scope.workspace.slug}/onboarding?#{[step: step]}"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, current: Enum.at(assigns.steps, assigns.step - 1))

    ~H"""
    <Layouts.public flash={@flash} nav={false}>
      <div class="mx-auto flex min-h-screen max-w-5xl flex-col px-4 py-8 sm:px-6">
        <div class="flex items-center justify-between gap-4">
          <Layouts.brand />
          <div class="flex items-center gap-2">
            <.color_scheme_switch id="onboarding-scheme" variant="toggle" />
            <.button
              variant="ghost"
              color="gray"
              size="sm"
              icon="hero-x-mark"
              phx-click="leave"
              phx-value-to="board"
              data-testid="onboarding-skip"
            >
              Pular a aula
            </.button>
          </div>
        </div>

        <div class="mt-10">
          <p class="text-sm font-semibold text-primary-600 dark:text-primary-400">
            Bem-vindo ao {@current_scope.workspace.name}
          </p>
          <h1 class="mt-1 text-2xl font-semibold tracking-tight text-gray-900 sm:text-3xl dark:text-white">
            Como colocar o PipeMaestro de pé
          </h1>
          <div class="mt-8" data-testid="onboarding-stepper">
            <.stepper
              size="sm"
              steps={
                for {step, index} <- Enum.with_index(@steps, 1) do
                  %{name: step.title, complete?: index < @step, active?: index == @step}
                end
              }
            />
          </div>
        </div>

        <section class="mt-10 flex-1" data-testid={"onboarding-step-#{@step}"}>
          <h2 class="text-xl font-semibold text-gray-900 dark:text-white">
            {@step}. {@current.title}
          </h2>
          <p class="mt-2 max-w-3xl text-base leading-7 text-gray-600 dark:text-gray-300">
            {@current.text}
          </p>
          <.command_block lines={@current.code} />
          <div class={["mt-6 grid gap-6", length(@current.shots) > 1 && "lg:grid-cols-2"]}>
            <.landing_shot :for={shot <- @current.shots} shot={shot} loading="eager" />
          </div>
          <a
            href={~p"/docs/primeiros-passos"}
            target="_blank"
            class="mt-4 inline-flex items-center gap-1 text-sm font-medium text-primary-600 hover:underline dark:text-primary-400"
            data-testid="onboarding-docs"
          >
            Ler mais na documentação
            <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" />
          </a>
        </section>

        <div class="mt-10 flex flex-col-reverse gap-3 border-t border-gray-200 pt-6 sm:flex-row sm:items-center sm:justify-between dark:border-gray-800">
          <div>
            <.button
              :if={@step > 1}
              to={step_path(@current_scope, @step - 1)}
              link_type="live_patch"
              variant="outline"
              color="gray"
              icon="hero-arrow-left"
              data-testid="onboarding-back"
            >
              Voltar
            </.button>
          </div>
          <div class="flex flex-col gap-3 sm:flex-row">
            <.button
              :if={@step < length(@steps)}
              to={step_path(@current_scope, @step + 1)}
              link_type="live_patch"
              icon="hero-arrow-right"
              icon_placement="right"
              data-testid="onboarding-next"
            >
              Próximo
            </.button>
            <.button
              :if={@step == length(@steps)}
              variant="outline"
              color="gray"
              phx-click="leave"
              phx-value-to="board"
              data-testid="onboarding-finish"
            >
              Ir para o board
            </.button>
            <.button
              :if={@step == length(@steps)}
              icon="hero-arrow-right"
              icon_placement="right"
              phx-click="leave"
              phx-value-to="runners"
              data-testid="onboarding-start-runner"
            >
              Começar: conectar o runner
            </.button>
          </div>
        </div>
      </div>
    </Layouts.public>
    """
  end
end
