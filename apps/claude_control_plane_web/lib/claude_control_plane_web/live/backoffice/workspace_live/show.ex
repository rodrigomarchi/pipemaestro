defmodule ClaudeControlPlaneWeb.Backoffice.WorkspaceLive.Show do
  @moduledoc """
  One workspace in the backoffice: its members, adding an existing user or
  creating a new one straight into it, and removing a member.
  """
  use ClaudeControlPlaneWeb, :live_view

  import ClaudeControlPlaneWeb.Backoffice.Components
  import ClaudeControlPlaneWeb.RunnerComponents

  alias ClaudeControlPlane.Accounts
  alias ClaudeControlPlane.Accounts.User
  alias ClaudeControlPlane.Runners
  alias ClaudeControlPlane.Workspaces
  alias ClaudeControlPlaneWeb.RunnerStatus
  alias Phoenix.Socket.Broadcast

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    workspace = Workspaces.get_workspace!(id)
    if connected?(socket), do: RunnerStatus.subscribe(workspace.id)

    {:ok,
     socket
     |> assign(page_title: workspace.name, workspace: workspace)
     |> assign(new_member_form: to_form(Accounts.change_user_registration(%User{})))
     |> load_members()
     |> load_runners()}
  end

  @impl true
  def handle_info(%Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, load_runners(socket)}

  def handle_info(:runners_changed, socket), do: {:noreply, load_runners(socket)}

  defp load_runners(socket) do
    workspace = socket.assigns.workspace

    assign(socket,
      runners: Runners.list_runners(workspace),
      online: RunnerStatus.online_ids(workspace.id),
      now: DateTime.utc_now()
    )
  end

  @impl true
  def handle_event("add_existing", %{"user_id" => user_id}, socket) when user_id != "" do
    user = Accounts.get_user!(user_id)

    case Workspaces.add_member(socket.assigns.workspace, user) do
      {:ok, _membership} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{user.name} agora faz parte de #{socket.assigns.workspace.name}.")
         |> load_members()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "#{user.name} já faz parte deste workspace.")}
    end
  end

  def handle_event("add_existing", _params, socket) do
    {:noreply, put_flash(socket, :error, "Escolha um usuário.")}
  end

  def handle_event("validate_new_member", %{"user" => params}, socket) do
    changeset = Accounts.change_user_registration(%User{}, params)
    {:noreply, assign(socket, new_member_form: to_form(changeset, action: :validate))}
  end

  def handle_event("create_new_member", %{"user" => params}, socket) do
    case Workspaces.create_member(socket.assigns.workspace, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{user.name} criado e adicionado ao workspace.")
         |> assign(new_member_form: to_form(Accounts.change_user_registration(%User{})))
         |> load_members()}

      {:error, changeset} ->
        {:noreply, assign(socket, new_member_form: to_form(changeset))}
    end
  end

  def handle_event("set_role", %{"user_id" => user_id, "role" => %{"role" => role}}, socket)
      when role in ["admin", "member"] do
    user = Accounts.get_user!(user_id)
    :ok = Workspaces.set_role(socket.assigns.workspace, user, String.to_existing_atom(role))

    {:noreply,
     socket
     |> put_flash(
       :info,
       "#{user.name} agora é #{role_label(role)} de #{socket.assigns.workspace.name}."
     )
     |> load_members()}
  end

  def handle_event("remove_member", %{"id" => user_id}, socket) do
    user = Accounts.get_user!(user_id)
    :ok = Workspaces.remove_member(socket.assigns.workspace, user)

    {:noreply,
     socket
     |> put_flash(:info, "#{user.name} saiu de #{socket.assigns.workspace.name}.")
     |> load_members()}
  end

  defp role_label("admin"), do: "admin"
  defp role_label("member"), do: "membro"

  defp member_count_label(1), do: "1 membro"
  defp member_count_label(count), do: "#{count} membros"

  defp load_members(socket) do
    workspace = socket.assigns.workspace

    assign(socket,
      members: Workspaces.list_memberships(workspace),
      candidates:
        Enum.map(Workspaces.list_non_members(workspace), &{"#{&1.name} · #{&1.email}", &1.id})
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.backoffice
      flash={@flash}
      current_operator={@current_operator}
      active={:workspaces}
      title={@workspace.name}
    >
      <:breadcrumb>
        <.link navigate={~p"/backoffice/workspaces"} class="hover:text-gray-900 dark:hover:text-white">
          Workspaces
        </.link>
      </:breadcrumb>
      <:actions>
        <.button
          size="sm"
          variant="outline"
          color="gray"
          icon="hero-pencil-square"
          to={~p"/backoffice/workspaces/#{@workspace}/edit"}
          link_type="live_redirect"
          data-testid="edit-workspace"
        >
          Editar
        </.button>
      </:actions>

      <div class="grid gap-6 xl:grid-cols-3">
        <div class="space-y-6 self-start xl:col-span-2">
          <.card variant="outline">
            <.card_header
              title="Membros"
              description={"Pessoas que entram em /w/#{@workspace.slug}."}
            >
              <:action>
                <.badge
                  color="gray"
                  variant="soft"
                  label={member_count_label(length(@members))}
                  data-testid="member-count"
                />
              </:action>
            </.card_header>
            <.table
              :if={@members != []}
              id="members"
              rows={@members}
              row_id={&"member-#{&1.user.id}"}
            >
              <:col :let={%{user: user}} label="Usuário">
                <.link
                  navigate={~p"/backoffice/users/#{user}"}
                  class="flex items-center gap-3"
                  data-testid={"member-#{user.email}"}
                >
                  <.avatar name={user.name} size="sm" random_color />
                  <span class="min-w-0">
                    <span class="block truncate font-medium text-gray-900 dark:text-white">
                      {user.name}
                    </span>
                    <span class="block truncate text-xs text-gray-500 dark:text-gray-400">
                      {user.email}
                    </span>
                  </span>
                </.link>
              </:col>
              <:col :let={%{user: user, role: role}} label="Papel">
                <.form
                  for={to_form(%{"role" => to_string(role)}, as: "role")}
                  id={"member-role-form-#{user.id}"}
                  phx-change="set_role"
                >
                  <input type="hidden" name="user_id" value={user.id} />
                  <.icon_field
                    field={to_form(%{"role" => to_string(role)}, as: "role")[:role]}
                    icon="hero-shield-check"
                    id={"member-role-#{user.id}"}
                    type="select"
                    label="Papel"
                    hide_label
                    options={[{"Admin", "admin"}, {"Membro", "member"}]}
                    data-testid={"member-role-#{user.email}"}
                  />
                </.form>
              </:col>
              <:col :let={%{user: user}} label="Status">
                <.status_badge
                  disabled_at={user.disabled_at}
                  data-testid={"member-status-#{user.email}"}
                />
              </:col>
              <:col :let={%{user: user}} label="" class="text-right">
                <.button
                  size="xs"
                  variant="ghost"
                  color="danger"
                  icon="hero-user-minus"
                  phx-click="remove_member"
                  phx-value-id={user.id}
                  data-confirm={"Remover #{user.name} de #{@workspace.name}?"}
                  data-testid={"member-remove-#{user.email}"}
                >
                  Remover
                </.button>
              </:col>
            </.table>
            <.card_content :if={@members == []}>
              <.empty
                data-testid="no-members"
                title="Nenhum membro ainda"
                description="Adicione um usuário existente ou crie um novo ao lado."
              >
                <:icon><.icon name="hero-users" /></:icon>
              </.empty>
            </.card_content>
          </.card>

          <.card variant="outline" data-testid="workspace-runners">
            <.card_header
              title="Runners"
              description="Executores conectados por membros deste workspace."
            >
              <:action>
                <.badge
                  color="success"
                  variant="soft"
                  label={"#{MapSet.size(@online)} online"}
                  data-testid="workspace-runners-online"
                />
              </:action>
            </.card_header>
            <.table
              :if={@runners != []}
              id="workspace-runners-table"
              rows={@runners}
              row_id={&"workspace-runner-#{&1.id}"}
            >
              <:col :let={runner} label="Runner">
                <span
                  class="font-medium text-gray-900 dark:text-white"
                  data-testid={"workspace-runner-#{runner.name}"}
                >
                  {runner.name}
                </span>
                <p class="font-mono text-xs text-gray-500">{runner.hostname}</p>
              </:col>
              <:col :let={runner} label="Status">
                <.runner_status
                  online={MapSet.member?(@online, runner.id)}
                  data-testid={"workspace-runner-status-#{runner.name}"}
                />
              </:col>
              <:col :let={runner} label="Versão">
                <span class="font-mono text-xs">{runner.runner_version}</span>
              </:col>
              <:col :let={runner} label="Visto">
                {if MapSet.member?(@online, runner.id),
                  do: "agora",
                  else: time_ago(runner.last_seen_at, @now)}
              </:col>
            </.table>
            <.card_content :if={@runners == []}>
              <p class="text-sm text-gray-500 dark:text-gray-400" data-testid="workspace-no-runners">
                Nenhum runner conectado a este workspace.
              </p>
            </.card_content>
          </.card>
        </div>

        <div class="space-y-6">
          <.card variant="outline">
            <.card_header
              title="Adicionar usuário existente"
              description="Uma pessoa pode estar em vários workspaces."
            />
            <.card_content>
              <.form for={%{}} id="add-existing-form" phx-submit="add_existing">
                <.icon_label icon="hero-user" label="Usuário" />
                <.combo_box
                  id="existing-user"
                  name="user_id"
                  label="Usuário"
                  placeholder={
                    if @candidates == [],
                      do: "Todos já fazem parte",
                      else: "Buscar por nome ou e-mail"
                  }
                  options={@candidates}
                  data-testid="add-existing-user"
                />
                <.button
                  type="submit"
                  class="mt-4 w-full"
                  variant="outline"
                  icon="hero-user-plus"
                  disabled={@candidates == []}
                  data-testid="add-existing-submit"
                >
                  Adicionar
                </.button>
              </.form>
            </.card_content>
          </.card>

          <.card variant="outline">
            <.card_header
              title="Criar novo usuário"
              description="Cria o acesso e já adiciona a este workspace."
            />
            <.card_content>
              <.form
                for={@new_member_form}
                id="new-member-form"
                phx-change="validate_new_member"
                phx-submit="create_new_member"
              >
                <.icon_field
                  field={@new_member_form[:name]}
                  icon="hero-user"
                  label="Nome"
                  data-testid="new-member-name"
                />
                <.icon_field
                  field={@new_member_form[:email]}
                  icon="hero-envelope"
                  type="email"
                  label="E-mail"
                  data-testid="new-member-email"
                />
                <.icon_field
                  field={@new_member_form[:password]}
                  icon="hero-key"
                  type="password"
                  label="Senha inicial"
                  help_text={password_hint()}
                  autocomplete="new-password"
                  viewable
                  data-testid="new-member-password"
                />
                <.button
                  type="submit"
                  class="w-full"
                  icon="hero-plus"
                  phx-disable-with="Criando…"
                  data-testid="new-member-submit"
                >
                  Criar e adicionar
                </.button>
              </.form>
            </.card_content>
          </.card>
        </div>
      </div>
    </Layouts.backoffice>
    """
  end
end
