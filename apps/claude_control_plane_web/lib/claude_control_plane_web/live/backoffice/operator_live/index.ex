defmodule ClaudeControlPlaneWeb.Backoffice.OperatorLive.Index do
  @moduledoc """
  Backoffice operators: list, create, disable and re-enable. An operator cannot
  disable themselves, so the backoffice is never left without anyone signed in.
  """
  use ClaudeControlPlaneWeb, :live_view

  import ClaudeControlPlaneWeb.Backoffice.Components

  alias ClaudeControlPlane.Backoffice
  alias ClaudeControlPlane.Backoffice.Operator
  alias ClaudeControlPlaneWeb.OperatorAuth

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, operators: Backoffice.list_operators())}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    case socket.assigns.live_action do
      :index ->
        {:noreply, assign(socket, page_title: "Operadores", form: nil)}

      :new ->
        {:noreply,
         assign(socket,
           page_title: "Novo operador",
           form: to_form(Backoffice.change_operator_registration(%Operator{}))
         )}
    end
  end

  @impl true
  def handle_event("validate", %{"operator" => params}, socket) do
    changeset = Backoffice.change_operator_registration(%Operator{}, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"operator" => params}, socket) do
    case Backoffice.create_operator(params) do
      {:ok, operator} ->
        {:noreply,
         socket
         |> put_flash(:info, "Operador #{operator.name} criado.")
         |> assign(operators: Backoffice.list_operators())
         |> push_patch(to: ~p"/backoffice/operators")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("disable", %{"id" => id}, socket) do
    if id == socket.assigns.current_operator.id do
      {:noreply, put_flash(socket, :error, "Você não pode desativar a si mesmo.")}
    else
      {:ok, operator} = Backoffice.disable_operator(Backoffice.get_operator!(id))
      OperatorAuth.disconnect_operator(operator)

      {:noreply,
       socket
       |> put_flash(:info, "#{operator.name} desativado. As sessões abertas foram encerradas.")
       |> assign(operators: Backoffice.list_operators())}
    end
  end

  def handle_event("enable", %{"id" => id}, socket) do
    {:ok, operator} = Backoffice.enable_operator(Backoffice.get_operator!(id))

    {:noreply,
     socket
     |> put_flash(:info, "#{operator.name} reativado.")
     |> assign(operators: Backoffice.list_operators())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.backoffice
      flash={@flash}
      current_operator={@current_operator}
      active={:operators}
      title="Operadores"
    >
      <:actions>
        <.button
          size="sm"
          icon="hero-plus"
          to={~p"/backoffice/operators/new"}
          link_type="live_patch"
          data-testid="new-operator"
        >
          Novo operador
        </.button>
      </:actions>

      <.alert color="warning" with_icon class="mb-6">
        Operadores têm acesso total ao backoffice: criam workspaces, usuários e outros operadores.
      </.alert>

      <.card variant="outline">
        <.table id="operators" rows={@operators} row_id={&"operator-#{&1.id}"}>
          <:col :let={operator} label="Operador">
            <div class="flex items-center gap-3" data-testid={"operator-#{operator.email}"}>
              <.avatar name={operator.name} size="sm" random_color />
              <span class="min-w-0">
                <span class="block truncate font-medium text-gray-900 dark:text-white">
                  {operator.name}
                  <span
                    :if={operator.id == @current_operator.id}
                    class="text-xs text-gray-400"
                    data-testid="operator-is-you"
                  >
                    (você)
                  </span>
                </span>
                <span class="block truncate text-xs text-gray-500 dark:text-gray-400">
                  {operator.email}
                </span>
              </span>
            </div>
          </:col>
          <:col :let={operator} label="Status">
            <.status_badge
              disabled_at={operator.disabled_at}
              data-testid={"operator-status-#{operator.email}"}
            />
          </:col>
          <:col :let={operator} label="Criado em">{format_date(operator.inserted_at)}</:col>
          <:col :let={operator} label="" class="text-right">
            <.button
              :if={is_nil(operator.disabled_at) and operator.id != @current_operator.id}
              size="xs"
              variant="ghost"
              color="danger"
              icon="hero-no-symbol"
              phx-click="disable"
              phx-value-id={operator.id}
              data-confirm={"Desativar #{operator.name}?"}
              data-testid={"operator-disable-#{operator.email}"}
            >
              Desativar
            </.button>
            <.button
              :if={operator.disabled_at}
              size="xs"
              variant="ghost"
              color="success"
              icon="hero-check"
              phx-click="enable"
              phx-value-id={operator.id}
              data-testid={"operator-enable-#{operator.email}"}
            >
              Reativar
            </.button>
          </:col>
        </.table>
      </.card>

      <.modal
        :if={@form}
        id="operator-modal"
        title={@page_title}
        on_cancel={JS.patch(~p"/backoffice/operators")}
      >
        <.form for={@form} id="operator-form" phx-change="validate" phx-submit="save">
          <.field field={@form[:name]} label="Nome" data-testid="operator-form-name" />
          <.field
            field={@form[:email]}
            type="email"
            label="E-mail"
            data-testid="operator-form-email"
          />
          <.field
            field={@form[:password]}
            type="password"
            label="Senha inicial"
            help_text={password_hint()}
            autocomplete="new-password"
            viewable
            data-testid="operator-form-password"
          />
          <div class="flex justify-end gap-2">
            <.button
              to={~p"/backoffice/operators"}
              link_type="live_patch"
              variant="ghost"
              color="gray"
              data-testid="operator-form-cancel"
            >
              Cancelar
            </.button>
            <.button type="submit" phx-disable-with="Criando…" data-testid="operator-form-submit">
              Criar operador
            </.button>
          </div>
        </.form>
      </.modal>
    </Layouts.backoffice>
    """
  end
end
