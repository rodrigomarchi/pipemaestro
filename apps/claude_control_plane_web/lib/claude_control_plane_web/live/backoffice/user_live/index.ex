defmodule ClaudeControlPlaneWeb.Backoffice.UserLive.Index do
  @moduledoc "Backoffice list of every workspace user, with create in a modal."
  use ClaudeControlPlaneWeb, :live_view

  import ClaudeControlPlaneWeb.Backoffice.Components

  alias ClaudeControlPlane.Accounts
  alias ClaudeControlPlane.Accounts.User

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
      <:actions>
        <.button
          size="sm"
          icon="hero-plus"
          to={~p"/backoffice/users/new"}
          link_type="live_patch"
          data-testid="new-user"
        >
          Novo usuário
        </.button>
      </:actions>

      <.card variant="outline">
        <.table
          :if={@users != []}
          id="users"
          rows={@users}
          row_id={&"user-#{&1.id}"}
          row_click={&JS.navigate(~p"/backoffice/users/#{&1}")}
        >
          <:col :let={user} label="Usuário">
            <div class="flex items-center gap-3" data-testid={"user-#{user.email}"}>
              <.avatar name={user.name} size="sm" random_color />
              <span class="min-w-0">
                <span class="block truncate font-medium text-gray-900 dark:text-white">
                  {user.name}
                </span>
                <span class="block truncate text-xs text-gray-500 dark:text-gray-400">
                  {user.email}
                </span>
              </span>
            </div>
          </:col>
          <:col :let={user} label="Workspaces">
            <div class="flex flex-wrap gap-1" data-testid={"user-workspaces-#{user.email}"}>
              <.badge
                :for={workspace <- user.workspaces}
                size="xs"
                color="gray"
                variant="outline"
                label={workspace.name}
              />
              <span :if={user.workspaces == []} class="text-xs text-gray-400">nenhum</span>
            </div>
          </:col>
          <:col :let={user} label="Status">
            <.status_badge disabled_at={user.disabled_at} data-testid={"user-status-#{user.email}"} />
          </:col>
          <:col :let={user} label="Criado em">{format_date(user.inserted_at)}</:col>
        </.table>

        <.card_content :if={@users == []}>
          <.empty
            data-testid="no-users"
            title="Nenhum usuário ainda"
            description="Crie usuários aqui ou direto na página de um workspace."
          >
            <:icon><.icon name="hero-users" /></:icon>
          </.empty>
        </.card_content>
      </.card>

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
          <div class="flex justify-end gap-2">
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
