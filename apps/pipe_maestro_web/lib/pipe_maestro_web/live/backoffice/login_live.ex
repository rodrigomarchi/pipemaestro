defmodule PipeMaestroWeb.Backoffice.LoginLive do
  @moduledoc """
  The backoffice sign-in screen. Submitting posts the form to
  `Backoffice.OperatorSessionController.create/2`.
  """
  use PipeMaestroWeb, :live_view

  alias PipeMaestro.Backoffice

  @impl true
  def mount(params, _session, socket) do
    form = to_form(%{"email" => params["email"] || "", "password" => ""}, as: "operator")
    {:ok, assign(socket, page_title: "Backoffice", form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.public flash={@flash} nav={false}>
      <div class="flex min-h-screen flex-col items-center justify-center bg-gray-50 px-6 py-12 dark:bg-gray-950">
        <div class="w-full max-w-sm">
          <div class="mb-8 flex items-center justify-between">
            <Layouts.brand />
            <.badge color="warning" variant="soft" label="Backoffice" />
          </div>

          <.card variant="outline">
            <.card_content class="p-6">
              <h1 class="text-xl font-semibold tracking-tight text-gray-900 dark:text-white">
                Acesso de operadores
              </h1>
              <p class="mt-1 mb-6 text-sm text-gray-600 dark:text-gray-400">
                Área restrita à equipe da plataforma.
              </p>

              <.form
                for={@form}
                id="operator-login-form"
                action={~p"/backoffice/login"}
                phx-submit="submit"
                phx-trigger-action={@trigger_submit}
              >
                <.icon_field
                  field={@form[:email]}
                  icon="hero-envelope"
                  type="email"
                  label="E-mail"
                  autocomplete="username"
                  required
                  data-testid="operator-login-email"
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
                  data-testid="operator-login-password"
                />
                <.button
                  type="submit"
                  class="w-full"
                  phx-disable-with="Entrando…"
                  data-testid="operator-login-submit"
                >
                  Entrar no backoffice
                </.button>
              </.form>
            </.card_content>
          </.card>

          <p class="mt-6 text-center text-xs text-gray-500 dark:text-gray-400">
            Sessões do backoffice expiram em {Backoffice.session_validity_in_hours()} horas.
          </p>
        </div>
      </div>
    </Layouts.public>
    """
  end
end
