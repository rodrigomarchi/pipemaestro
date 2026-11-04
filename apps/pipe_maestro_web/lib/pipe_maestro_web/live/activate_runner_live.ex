defmodule PipeMaestroWeb.ActivateRunnerLive do
  @moduledoc """
  Where a person approves a runner's sign-in: they type (or follow a link with)
  the code the runner printed, check what is asking, pick the workspace and the
  name, and approve or deny.
  """
  use PipeMaestroWeb, :live_view

  alias PipeMaestro.{Runners, Workspaces}

  @impl true
  def mount(params, _session, socket) do
    # Only a workspace's admins connect runners to it.
    workspaces =
      Workspaces.list_workspaces_for_user(socket.assigns.current_scope.user, role: :admin)

    socket =
      assign(socket,
        page_title: "Conectar runner",
        workspaces: workspaces,
        auth: nil,
        result: nil,
        code_form: to_form(%{"code" => params["code"] || ""}, as: "lookup")
      )

    {:ok, if(params["code"], do: lookup(socket, params["code"]), else: socket)}
  end

  @impl true
  def handle_event("lookup", %{"lookup" => %{"code" => code}}, socket) do
    {:noreply, lookup(socket, code)}
  end

  def handle_event("approve", %{"approval" => %{"workspace_id" => id, "name" => name}}, socket) do
    user = socket.assigns.current_scope.user

    with %{} = workspace <- Enum.find(socket.assigns.workspaces, &(&1.id == id)),
         {:ok, runner} <-
           Runners.approve_device_authorization(socket.assigns.auth, user, workspace, name) do
      {:noreply, assign(socket, result: %{runner: runner, workspace: workspace}, auth: nil)}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, approval_form: to_form(changeset, as: "approval"))}

      _expired_or_not_member ->
        {:noreply,
         socket
         |> put_flash(:error, "Esse pedido expirou ou não pode ser aprovado aqui.")
         |> assign(auth: nil)}
    end
  end

  def handle_event("deny", _params, socket) do
    _ = Runners.deny_device_authorization(socket.assigns.auth)
    {:noreply, assign(socket, result: :denied, auth: nil)}
  end

  defp lookup(socket, code) do
    case Runners.get_pending_authorization(code) do
      nil ->
        socket
        |> assign(auth: nil, code_form: to_form(%{"code" => code}, as: "lookup"))
        |> put_flash(:error, "Código inválido ou expirado. Rode o login do runner de novo.")

      auth ->
        approval = %{
          "workspace_id" => default_workspace_id(socket.assigns.workspaces),
          "name" => auth.name
        }

        assign(socket, auth: auth, approval_form: to_form(approval, as: "approval"))
    end
  end

  defp default_workspace_id([workspace | _]), do: workspace.id
  defp default_workspace_id([]), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.public flash={@flash} nav={false}>
      <div class="mx-auto flex min-h-screen max-w-xl flex-col px-6 py-10">
        <Layouts.brand />

        <div class="flex flex-1 flex-col justify-center py-12">
          <h1 class="text-2xl font-semibold tracking-tight text-gray-900 dark:text-white">
            Conectar um runner
          </h1>

          <.card :if={is_nil(@auth) and is_nil(@result)} variant="outline" class="mt-6">
            <.card_content>
              <p class="mb-4 text-sm text-gray-600 dark:text-gray-400">
                Digite o código que o comando <code>runner.login</code> mostrou no terminal.
              </p>
              <.form for={@code_form} id="activate-code-form" phx-submit="lookup">
                <.icon_field
                  field={@code_form[:code]}
                  icon="hero-hashtag"
                  label="Código"
                  placeholder="WDJB-MJHT"
                  autocomplete="off"
                  data-testid="activate-code"
                />
                <.button type="submit" class="w-full" data-testid="activate-lookup">
                  Continuar
                </.button>
              </.form>
            </.card_content>
          </.card>

          <.card :if={@auth} variant="outline" class="mt-6" data-testid="activate-request">
            <.card_content class="space-y-6">
              <div>
                <p class="text-sm text-gray-500 dark:text-gray-400">Pedido de conexão</p>
                <p
                  class="mt-1 font-mono text-lg font-semibold text-gray-900 dark:text-white"
                  data-testid="activate-hostname"
                >
                  {@auth.requested["hostname"]}
                </p>
                <p class="text-sm text-gray-600 dark:text-gray-400">
                  {@auth.requested["os"]}/{@auth.requested["arch"]} · capacidade {@auth.requested[
                    "capacity"
                  ]} · runner {@auth.requested["runner_version"]}
                </p>
                <div class="mt-2 flex flex-wrap gap-1">
                  <.badge
                    :for={label <- @auth.requested["labels"] || []}
                    size="xs"
                    color="gray"
                    variant="outline"
                    label={label}
                  />
                </div>
              </div>

              <.alert :if={@workspaces == []} color="warning">
                Você não é admin de nenhum workspace, então não pode aprovar runners.
              </.alert>

              <.form
                :if={@workspaces != []}
                for={@approval_form}
                id="activate-approval-form"
                phx-submit="approve"
              >
                <.icon_field
                  field={@approval_form[:workspace_id]}
                  icon="hero-building-office"
                  type="select"
                  label="Workspace"
                  options={Enum.map(@workspaces, &{&1.name, &1.id})}
                  data-testid="activate-workspace"
                />
                <.icon_field
                  field={@approval_form[:name]}
                  icon="hero-tag"
                  label="Nome do runner"
                  data-testid="activate-name"
                />
                <div class="flex gap-2">
                  <.button type="submit" class="flex-1" data-testid="activate-approve">
                    Aprovar
                  </.button>
                  <.button
                    type="button"
                    variant="outline"
                    color="gray"
                    phx-click="deny"
                    data-testid="activate-deny"
                  >
                    Recusar
                  </.button>
                </div>
              </.form>
            </.card_content>
          </.card>

          <.card :if={is_map(@result)} variant="outline" class="mt-6">
            <.card_content data-testid="activate-approved">
              <p class="font-semibold text-gray-900 dark:text-white">
                Runner {@result.runner.name} aprovado em {@result.workspace.name}.
              </p>
              <p class="mt-1 text-sm text-gray-600 dark:text-gray-400">
                Volte ao terminal: o login termina sozinho em alguns segundos.
              </p>
              <.button
                class="mt-4"
                to={~p"/w/#{@result.workspace.slug}/runners"}
                link_type="a"
                data-testid="activate-go-to-runners"
              >
                Ver runners do workspace
              </.button>
            </.card_content>
          </.card>

          <.card :if={@result == :denied} variant="outline" class="mt-6">
            <.card_content data-testid="activate-denied">
              <p class="font-semibold text-gray-900 dark:text-white">Pedido recusado.</p>
              <p class="mt-1 text-sm text-gray-600 dark:text-gray-400">
                O runner vai mostrar que o acesso foi negado.
              </p>
            </.card_content>
          </.card>
        </div>
      </div>
    </Layouts.public>
    """
  end
end
