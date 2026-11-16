defmodule PipeMaestroWeb.RegistrationLive do
  @moduledoc """
  The sign-up screen of the Free beta plan (ADR 0058). It checks the form as it
  is typed, except whether the e-mail is taken; a valid form is posted to
  `UserRegistrationController.create/2`, which creates the account and signs
  it in, or sends it back here (filled in from the session) with the reason.
  """
  use PipeMaestroWeb, :live_view

  alias PipeMaestro.Accounts
  alias PipeMaestro.Accounts.User

  @impl true
  def mount(_params, session, socket) do
    attrs = Map.take(session["signup"] || %{}, ["name", "email"])

    {:ok,
     socket
     |> assign(page_title: "Criar conta", trigger_submit: false)
     |> assign_form(change(attrs))}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    {:noreply, assign_form(socket, params |> change() |> Map.put(:action, :validate))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    changeset = change(params)

    if changeset.valid? do
      {:noreply, socket |> assign(trigger_submit: true) |> assign_form(changeset)}
    else
      {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}
    end
  end

  # Never asks whether the e-mail is taken: only the rate-limited POST tells.
  defp change(attrs),
    do: Accounts.change_user_registration(%User{}, attrs, validate_unique: false)

  defp assign_form(socket, changeset), do: assign(socket, form: to_form(changeset, as: "user"))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.public flash={@flash} nav={false}>
      <div class="grid min-h-screen lg:grid-cols-2">
        <div class="flex flex-col px-6 py-10 sm:px-12">
          <div class="flex items-center justify-between">
            <Layouts.brand />
            <.color_scheme_switch id="signup-scheme" variant="toggle" />
          </div>

          <div class="mx-auto flex w-full max-w-sm flex-1 flex-col justify-center py-12">
            <div class="flex items-center gap-2">
              <h1 class="text-2xl font-semibold tracking-tight text-gray-900 dark:text-white">
                Crie a sua conta
              </h1>
            </div>
            <p class="mt-2 mb-8 flex items-center gap-2 text-sm text-gray-600 dark:text-gray-400">
              Plano Free <.badge color="primary" variant="soft" size="sm" label="BETA" />
              · grátis, sem cartão
            </p>

            <.form
              for={@form}
              id="signup-form"
              data-testid="signup-form"
              action={~p"/signup"}
              phx-change="validate"
              phx-submit="save"
              phx-trigger-action={@trigger_submit}
            >
              <.icon_field
                field={@form[:name]}
                icon="hero-user"
                label="Nome"
                placeholder="Seu nome"
                autocomplete="name"
                required
                phx-debounce="blur"
                data-testid="signup-name"
                phx-mounted={JS.focus()}
              />
              <.icon_field
                field={@form[:email]}
                icon="hero-envelope"
                type="email"
                label="E-mail"
                placeholder="voce@empresa.com"
                autocomplete="username"
                required
                phx-debounce="blur"
                data-testid="signup-email"
              />
              <.icon_field
                field={@form[:password]}
                icon="hero-lock-closed"
                type="password"
                label="Senha"
                autocomplete="new-password"
                required
                viewable
                phx-debounce="blur"
                help_text={"Pelo menos #{PipeMaestro.Auth.Credentials.min_password_length()} caracteres."}
                data-testid="signup-password"
              />
              <.button
                type="submit"
                class="w-full"
                size="lg"
                phx-disable-with="Criando a conta…"
                data-testid="signup-submit"
              >
                Criar conta
              </.button>
            </.form>

            <p class="mt-8 text-center text-sm text-gray-500 dark:text-gray-400">
              Já tem conta?
              <.link
                navigate={~p"/login"}
                class="font-medium text-primary-600 hover:underline dark:text-primary-400"
                data-testid="signup-login-link"
              >
                Entrar
              </.link>
            </p>
          </div>
        </div>

        <div class="relative hidden overflow-hidden bg-gradient-to-br from-primary-700 via-primary-600 to-secondary-600 lg:flex lg:flex-col lg:justify-center lg:p-12">
          <div
            class="absolute inset-0 bg-[radial-gradient(circle_at_30%_20%,rgba(255,255,255,0.18),transparent_45%)]"
            aria-hidden="true"
          />
          <div class="relative max-w-md text-white">
            <p class="text-3xl font-semibold leading-tight">
              Da issue ao Pull Request, em poucos minutos de configuração.
            </p>
            <ul class="mt-8 space-y-4 text-white/90">
              <li
                :for={
                  {icon, text} <- [
                    {"hero-computer-desktop", "Conecte a sua máquina como runner"},
                    {"hero-folder", "Diga onde está o código e como testá-lo"},
                    {"hero-arrow-path-rounded-square", "Escolha um pipeline pronto e crie a tarefa"}
                  ]
                }
                class="flex items-center gap-3"
              >
                <span class="inline-flex size-9 shrink-0 items-center justify-center rounded-full bg-white/15">
                  <.icon name={icon} class="size-5" />
                </span>
                {text}
              </li>
            </ul>
          </div>
        </div>
      </div>
    </Layouts.public>
    """
  end
end
