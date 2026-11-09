defmodule PipeMaestroWeb.Backoffice.UserLive.Index do
  @moduledoc "Backoffice list of every workspace user, with create in a modal."
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.Backoffice.Components

  alias PipeMaestro.Accounts
  alias PipeMaestro.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, users: Accounts.list_users())}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    case socket.assigns.live_action do
      :index ->
        {:noreply, assign(socket, page_title: "Usuários", form: nil)}

      :new ->
        {:noreply,
         assign(socket,
           page_title: "Novo usuário",
           form: to_form(Accounts.change_user_registration(%User{}))
         )}
    end
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset = Accounts.change_user_registration(%User{}, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.create_user(params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{user.name} criado. Adicione-o a um workspace.")
         |> push_navigate(to: ~p"/backoffice/users/#{user}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.backoffice
      flash={@flash}
      current_operator={@current_operator}
      active={:users}
      title="Usuários"
    >
      <:action
        label="Novo usuário"
        icon="hero-plus"
        patch={~p"/backoffice/users/new"}
        primary
        testid="new-user"
      />

      <.record_list id="users" testid="users" empty={@users == []}>
        <.record_card
          :for={user <- @users}
          id={"user-#{user.id}"}
          testid={"user-#{user.email}"}
          navigate={~p"/backoffice/users/#{user}"}
        >
          <:leading><.avatar name={user.name} size="sm" random_color /></:leading>
          <:title>{user.name}</:title>
          <:badge>
            <.status_badge disabled_at={user.disabled_at} data-testid={"user-status-#{user.email}"} />
          </:badge>
          <:meta>{user.email}</:meta>
          <:meta>
            <span class="flex flex-wrap gap-1" data-testid={"user-workspaces-#{user.email}"}>
              <.badge
                :for={workspace <- user.workspaces}
                size="xs"
                color="gray"
                variant="outline"
                label={workspace.name}
              />
              <span :if={user.workspaces == []} class="text-gray-400">nenhum workspace</span>
            </span>
          </:meta>
          <:aside>criado em {format_date(user.inserted_at)}</:aside>
        </.record_card>
        <:empty_state>
          <.record_empty
            testid="no-users"
            icon="hero-users"
            title="Nenhum usuário ainda"
            description="Crie usuários aqui ou direto na página de um workspace."
          />
        </:empty_state>
      </.record_list>

      <.modal
        :if={@form}
        id="user-modal"
        title={@page_title}
        on_cancel={JS.patch(~p"/backoffice/users")}
      >
        <.form for={@form} id="user-form" phx-change="validate" phx-submit="save">
          <.icon_field
            field={@form[:name]}
            icon="hero-user"
            label="Nome"
            data-testid="user-form-name"
          />
          <.icon_field
            field={@form[:email]}
            icon="hero-envelope"
            type="email"
            label="E-mail"
            data-testid="user-form-email"
          />
          <.icon_field
            field={@form[:password]}
            icon="hero-key"
            type="password"
            label="Senha inicial"
            help_text={password_hint()}
            autocomplete="new-password"
            viewable
            data-testid="user-form-password"
          />
          <div class="flex flex-wrap justify-end gap-2">
            <.button
              to={~p"/backoffice/users"}
              link_type="live_patch"
              variant="ghost"
              color="gray"
              data-testid="user-form-cancel"
            >
              Cancelar
            </.button>
            <.button type="submit" phx-disable-with="Criando…" data-testid="user-form-submit">
              Criar usuário
            </.button>
          </div>
        </.form>
      </.modal>
    </Layouts.backoffice>
    """
  end
end
