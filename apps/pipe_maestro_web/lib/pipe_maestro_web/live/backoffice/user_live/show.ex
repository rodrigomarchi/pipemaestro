defmodule PipeMaestroWeb.Backoffice.UserLive.Show do
  @moduledoc """
  One user in the backoffice: workspaces they belong to, a new password, and
  disabling or re-enabling their access. Resetting and disabling both end every
  session the user has open.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.Backoffice.Components

  alias PipeMaestro.{Accounts, Workspaces}
  alias PipeMaestroWeb.UserAuth

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign_user(Accounts.get_user!(id))
     |> assign(password_form: nil)}
  end

  @impl true
  def handle_event("add_workspace", %{"workspace_id" => id}, socket) when id != "" do
    workspace = Workspaces.get_workspace!(id)
    user = socket.assigns.user

    case Workspaces.add_member(workspace, user) do
      {:ok, _membership} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{user.name} agora faz parte de #{workspace.name}.")
         |> assign_user(Accounts.get_user!(user.id))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "#{user.name} já faz parte de #{workspace.name}.")}
    end
  end

  def handle_event("add_workspace", _params, socket) do
    {:noreply, put_flash(socket, :error, "Escolha um workspace.")}
  end

  def handle_event("remove_workspace", %{"id" => id}, socket) do
    workspace = Workspaces.get_workspace!(id)
    user = socket.assigns.user
    :ok = Workspaces.remove_member(workspace, user)

    {:noreply,
     socket
     |> put_flash(:info, "#{user.name} saiu de #{workspace.name}.")
     |> assign_user(Accounts.get_user!(user.id))}
  end

  def handle_event("open_password", _params, socket) do
    {:noreply,
     assign(socket, password_form: to_form(Accounts.change_user_password(socket.assigns.user)))}
  end

  def handle_event("close_password", _params, socket) do
    {:noreply, assign(socket, password_form: nil)}
  end

  def handle_event("validate_password", %{"user" => params}, socket) do
    changeset = Accounts.change_user_password(socket.assigns.user, params)
    {:noreply, assign(socket, password_form: to_form(changeset, action: :validate))}
  end

  def handle_event("reset_password", %{"user" => params}, socket) do
    case Accounts.reset_user_password(socket.assigns.user, params) do
      {:ok, user} ->
        UserAuth.disconnect_user(user)

        {:noreply,
         socket
         |> put_flash(
           :info,
           "Senha de #{user.name} redefinida. As sessões abertas foram encerradas."
         )
         |> assign(password_form: nil)}

      {:error, changeset} ->
        {:noreply, assign(socket, password_form: to_form(changeset))}
    end
  end

  def handle_event("disable", _params, socket) do
    {:ok, user} = Accounts.disable_user(socket.assigns.user)
    UserAuth.disconnect_user(user)

    {:noreply,
     socket
     |> put_flash(:info, "#{user.name} desativado. As sessões abertas foram encerradas.")
     |> assign_user(Accounts.get_user!(user.id))}
  end

  def handle_event("enable", _params, socket) do
    {:ok, user} = Accounts.enable_user(socket.assigns.user)

    {:noreply,
     socket
     |> put_flash(:info, "#{user.name} reativado.")
     |> assign_user(Accounts.get_user!(user.id))}
  end

  defp assign_user(socket, user) do
    joined = MapSet.new(user.workspaces, & &1.id)

    assign(socket,
      page_title: user.name,
      user: user,
      other_workspaces:
        for(w <- Workspaces.list_workspaces(), w.id not in joined, do: {w.name, w.id})
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.backoffice
      flash={@flash}
      current_operator={@current_operator}
      active={:users}
      title={@user.name}
      back={%{to: ~p"/backoffice/users", label: "Usuários", testid: "back-to-users"}}
    >
      <div class="space-y-6">
        <.card variant="outline">
          <.card_content class="flex flex-wrap items-center gap-4">
            <.avatar name={@user.name} size="lg" random_color />
            <div class="min-w-0 flex-1">
              <p class="text-lg font-semibold text-gray-900 dark:text-white" data-testid="user-name">
                {@user.name}
              </p>
              <p class="text-sm text-gray-500 dark:text-gray-400" data-testid="user-email">
                {@user.email}
              </p>
              <p class="mt-1 text-xs text-gray-400">Criado em {format_date(@user.inserted_at)}</p>
            </div>
            <.status_badge disabled_at={@user.disabled_at} data-testid="user-status" />
          </.card_content>
        </.card>

        <.card variant="outline">
          <.card_header title="Acesso" />
          <.card_content class="grid gap-6 sm:grid-cols-2">
            <div>
              <p class="text-sm font-medium text-gray-900 dark:text-white">Senha</p>
              <p class="mt-1 mb-3 text-sm text-gray-500 dark:text-gray-400">
                Define uma senha nova e encerra todas as sessões abertas.
              </p>
              <.button
                variant="outline"
                color="gray"
                icon="hero-key"
                phx-click="open_password"
                data-testid="reset-password"
              >
                Redefinir senha
              </.button>
            </div>

            <div :if={is_nil(@user.disabled_at)}>
              <p class="text-sm font-medium text-gray-900 dark:text-white">Desativar acesso</p>
              <p class="mt-1 mb-3 text-sm text-gray-500 dark:text-gray-400">
                Bloqueia o login e encerra as sessões. Nada é apagado.
              </p>
              <.button
                color="danger"
                variant="outline"
                icon="hero-no-symbol"
                phx-click="disable"
                data-confirm={"Desativar #{@user.name}?"}
                data-testid="disable-user"
              >
                Desativar usuário
              </.button>
            </div>

            <div :if={@user.disabled_at}>
              <p class="text-sm font-medium text-gray-900 dark:text-white">Acesso desativado</p>
              <p class="mt-1 mb-3 text-sm text-gray-500 dark:text-gray-400">
                Desde {format_date(@user.disabled_at)}. Reativar permite entrar de novo com a
                senha atual.
              </p>
              <.button
                color="success"
                variant="outline"
                icon="hero-check"
                phx-click="enable"
                data-testid="enable-user"
              >
                Reativar usuário
              </.button>
            </div>
          </.card_content>
        </.card>

        <.card variant="outline">
          <.card_header title="Workspaces" description="Onde este usuário pode entrar." />
          <.card_content :if={@user.workspaces != []}>
            <.record_list id="user-workspaces">
              <.record_card
                :for={workspace <- @user.workspaces}
                id={"user-workspace-#{workspace.id}"}
                testid={"user-workspace-row-#{workspace.slug}"}
                navigate={~p"/backoffice/workspaces/#{workspace}"}
                link_testid={"user-workspace-#{workspace.slug}"}
                dense
              >
                <:leading>
                  <.avatar name={workspace.name} size="sm" random_color shape="rounded" />
                </:leading>
                <:title>{workspace.name}</:title>
                <:meta><span class="font-mono">/w/{workspace.slug}</span></:meta>
                <:actions>
                  <.button
                    size="xs"
                    variant="ghost"
                    color="danger"
                    icon="hero-minus-circle"
                    phx-click="remove_workspace"
                    phx-value-id={workspace.id}
                    data-confirm={"Remover #{@user.name} de #{workspace.name}?"}
                    data-testid={"user-workspace-remove-#{workspace.slug}"}
                  >
                    Remover
                  </.button>
                </:actions>
              </.record_card>
            </.record_list>
          </.card_content>
          <.card_content>
            <p
              :if={@user.workspaces == []}
              data-testid="no-user-workspaces"
              class="mb-4 text-sm text-gray-500 dark:text-gray-400"
            >
              Ainda não faz parte de nenhum workspace e por isso não consegue usar o produto.
            </p>
            <.form
              :if={@other_workspaces != []}
              for={%{}}
              id="add-workspace-form"
              phx-submit="add_workspace"
              class="flex items-end gap-2"
            >
              <div class="flex-1">
                <.icon_label icon="hero-building-office" label="Adicionar a um workspace" />
                <.combo_box
                  id="add-workspace"
                  name="workspace_id"
                  label="Adicionar a um workspace"
                  placeholder="Buscar workspace"
                  options={@other_workspaces}
                  data-testid="add-to-workspace"
                />
              </div>
              <.button
                type="submit"
                variant="outline"
                icon="hero-plus"
                data-testid="add-to-workspace-submit"
              >
                Adicionar
              </.button>
            </.form>
          </.card_content>
        </.card>
      </div>

      <.modal
        :if={@password_form}
        id="password-modal"
        title={"Nova senha para #{@user.name}"}
        on_cancel={JS.push("close_password")}
      >
        <.form
          for={@password_form}
          id="password-form"
          phx-change="validate_password"
          phx-submit="reset_password"
        >
          <.icon_field
            field={@password_form[:password]}
            icon="hero-key"
            type="password"
            label="Nova senha"
            help_text={password_hint()}
            autocomplete="new-password"
            viewable
            data-testid="new-password"
          />
          <div class="flex flex-wrap justify-end gap-2">
            <.button
              type="button"
              variant="ghost"
              color="gray"
              phx-click="close_password"
              data-testid="reset-password-cancel"
            >
              Cancelar
            </.button>
            <.button type="submit" phx-disable-with="Salvando…" data-testid="reset-password-submit">
              Redefinir senha
            </.button>
          </div>
        </.form>
      </.modal>
    </Layouts.backoffice>
    """
  end
end
