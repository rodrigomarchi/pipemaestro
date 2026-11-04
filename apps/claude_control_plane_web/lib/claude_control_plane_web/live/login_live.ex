defmodule ClaudeControlPlaneWeb.LoginLive do
  @moduledoc """
  The workspace sign-in screen. Submitting posts the form to
  `UserSessionController.create/2`, which checks the credentials and writes the
  session cookie.
  """
  use ClaudeControlPlaneWeb, :live_view

  @impl true
  def mount(params, _session, socket) do
    form =
      to_form(%{"email" => params["email"] || "", "password" => "", "remember_me" => "true"},
        as: "user"
      )

    {:ok, assign(socket, page_title: "Entrar", form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.public flash={@flash} nav={false}>
      <div class="grid min-h-screen lg:grid-cols-2">
        <div class="flex flex-col px-6 py-10 sm:px-12">
          <div class="flex items-center justify-between">
            <Layouts.brand />
            <.color_scheme_switch id="login-scheme" variant="toggle" />
          </div>

          <div class="mx-auto flex w-full max-w-sm flex-1 flex-col justify-center py-12">
            <h1 class="text-2xl font-semibold tracking-tight text-gray-900 dark:text-white">
              Entrar na sua organização
            </h1>
            <p class="mt-2 mb-8 text-sm text-gray-600 dark:text-gray-400">
              Use o e-mail e a senha que a equipe da plataforma criou para você.
            </p>

            <.form
              for={@form}
              id="login-form"
              action={~p"/login"}
              phx-submit="submit"
              phx-trigger-action={@trigger_submit}
            >
              <.icon_field
                field={@form[:email]}
                icon="hero-envelope"
                type="email"
                label="E-mail"
                placeholder="voce@empresa.com"
                autocomplete="username"
                required
                data-testid="login-email"
                phx-mounted={JS.focus()}
              />
              <.icon_field
                field={@form[:password]}
                icon="hero-lock-closed"
                type="password"
                label="Senha"
                autocomplete="current-password"
                required
                viewable
                data-testid="login-password"
              />
              <.icon_field
                field={@form[:remember_me]}
                icon="hero-clock"
                type="checkbox"
                label="Manter conectado"
                data-testid="login-remember"
              />
              <.button
                type="submit"
                class="w-full"
                size="lg"
                phx-disable-with="Entrando…"
                data-testid="login-submit"
              >
                Entrar
              </.button>
            </.form>

            <p class="mt-8 text-center text-sm text-gray-500 dark:text-gray-400">
              Esqueceu a senha ou ainda não tem acesso? Fale com o administrador da sua
              organização.
            </p>
          </div>
        </div>

        <div class="relative hidden overflow-hidden bg-gradient-to-br from-primary-700 via-primary-600 to-secondary-600 lg:flex lg:flex-col lg:justify-between lg:p-12">
          <div
            class="absolute inset-0 bg-[radial-gradient(circle_at_30%_20%,rgba(255,255,255,0.18),transparent_45%)]"
            aria-hidden="true"
          />
          <div class="relative max-w-md text-white">
            <p class="text-3xl font-semibold leading-tight">
              Gates objetivos, decisões humanas e um PR pronto para revisão.
            </p>
            <p class="mt-4 text-white/80">
              O pipeline pausa e pergunta quando precisa. Você decide; ele retoma de onde parou.
            </p>
          </div>
          <.card class="relative max-w-md">
            <.card_content>
              <div class="flex items-start gap-3">
                <span class="inline-flex size-9 shrink-0 items-center justify-center rounded-full bg-warning-100 text-warning-600 dark:bg-warning-500/15 dark:text-warning-400">
                  <.icon name="hero-hand-raised" class="size-5" />
                </span>
                <div class="min-w-0">
                  <p class="text-sm font-semibold text-gray-900 dark:text-white">
                    Decisão pendente · acme/api #455
                  </p>
                  <p class="mt-1 text-sm text-gray-600 dark:text-gray-400">
                    O plano altera o contrato público de /v1/customers. Aprovar?
                  </p>
                  <div class="mt-3 flex gap-2">
                    <.button size="xs">Aprovar</.button>
                    <.button size="xs" variant="outline" color="gray">Ajustar plano</.button>
                  </div>
                </div>
              </div>
            </.card_content>
          </.card>
        </div>
      </div>
    </Layouts.public>
    """
  end
end
