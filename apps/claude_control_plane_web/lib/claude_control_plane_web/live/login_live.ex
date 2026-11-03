defmodule ClaudeControlPlaneWeb.LoginLive do
  @moduledoc """
  The sign-in screen.

  Authentication does not exist yet: any submission goes straight to the board.
  """
  use ClaudeControlPlaneWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    form = to_form(%{"email" => "", "password" => "", "remember" => "true"}, as: :session)
    {:ok, assign(socket, page_title: "Entrar", form: form)}
  end

  @impl true
  def handle_event("sign_in", _params, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Que bom ter você de volta!")
     |> push_navigate(to: ~p"/app")}
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
            <p class="mt-2 text-sm text-gray-600 dark:text-gray-400">
              Use a conta do GitHub conectada à sua organização ou o seu e-mail.
            </p>

            <div class="mt-8 space-y-3">
              <.social_button
                provider="github"
                variant="solid"
                class="w-full"
                phx-click="sign_in"
                label="Continuar com GitHub"
              />
            </div>

            <div class="my-6 flex items-center gap-3 text-xs uppercase tracking-wide text-gray-400">
              <.separator class="flex-1" /> ou <.separator class="flex-1" />
            </div>

            <.form for={@form} id="login-form" phx-submit="sign_in" class="space-y-1">
              <.field
                field={@form[:email]}
                type="email"
                label="E-mail"
                placeholder="voce@empresa.com"
                autocomplete="email"
              />
              <.field
                field={@form[:password]}
                type="password"
                label="Senha"
                placeholder="••••••••"
                autocomplete="current-password"
                viewable
              />
              <div class="flex items-center justify-between pb-4">
                <.field field={@form[:remember]} type="checkbox" label="Manter conectado" />
                <.link
                  navigate={~p"/login"}
                  class="text-sm font-medium text-primary-600 hover:text-primary-500 dark:text-primary-400"
                >
                  Esqueceu a senha?
                </.link>
              </div>
              <.button type="submit" class="w-full" size="lg">Entrar</.button>
            </.form>

            <p class="mt-8 text-center text-sm text-gray-500 dark:text-gray-400">
              Ainda não tem conta?
              <.link
                navigate={~p"/login"}
                class="font-medium text-primary-600 hover:text-primary-500 dark:text-primary-400"
              >
                Fale com a gente
              </.link>
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
