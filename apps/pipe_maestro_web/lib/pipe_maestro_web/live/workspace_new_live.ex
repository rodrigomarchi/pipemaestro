defmodule PipeMaestroWeb.WorkspaceNewLive do
  @moduledoc """
  Where someone creates a workspace of their own, on the Free beta plan
  (ADR 0058): its name and its address. For someone who just signed up, it is
  the second and last step. Past the plan's number of workspaces, it sends
  them back to their workspaces.

  The board lives in another live_session, so going to it is a full
  navigation.
  """
  use PipeMaestroWeb, :live_view

  alias PipeMaestro.Workspaces
  alias PipeMaestro.Workspaces.Plan

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    if Workspaces.can_create_workspace?(user) do
      {:ok,
       socket
       |> assign(
         page_title: "Novo workspace",
         first?: Workspaces.list_workspaces_for_user(user) == []
       )
       |> assign_form(Workspaces.change_owned_workspace())}
    else
      {:ok, limit_reached(socket)}
    end
  end

  @impl true
  def handle_event("validate", %{"workspace" => params}, socket) do
    changeset = params |> Workspaces.change_owned_workspace() |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"workspace" => params}, socket) do
    case Workspaces.create_owned_workspace(socket.assigns.current_scope.user, params) do
      {:ok, workspace} ->
        {:noreply, redirect(socket, to: ~p"/w/#{workspace.slug}")}

      {:error, :limit_reached} ->
        {:noreply, limit_reached(socket)}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp limit_reached(socket) do
    socket
    |> put_flash(
      :error,
      "Você chegou ao limite de #{Plan.free_beta().workspaces_per_owner} workspaces do plano Free."
    )
    |> redirect(to: ~p"/workspaces")
  end

  defp assign_form(socket, changeset) do
    assign(socket,
      form: to_form(changeset, as: "workspace"),
      slug: Ecto.Changeset.get_field(changeset, :slug)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.public flash={@flash} nav={false}>
      <div class="mx-auto flex min-h-screen max-w-xl flex-col px-6 py-10">
        <div class="flex items-center justify-between">
          <Layouts.brand />
          <.color_scheme_switch id="workspace-new-scheme" variant="toggle" />
        </div>

        <div class="flex flex-1 flex-col justify-center py-12">
          <.link
            :if={!@first?}
            navigate={~p"/workspaces?#{[choose: 1]}"}
            class="mb-8 inline-flex items-center gap-1 self-start text-sm font-medium text-gray-600 hover:text-gray-900 dark:text-gray-400 dark:hover:text-white"
            data-testid="workspace-new-back"
          >
            <.icon name="hero-arrow-left-micro" class="size-4" /> Seus workspaces
          </.link>
          <div :if={@first?} class="mb-10" data-testid="workspace-new-stepper">
            <.stepper
              size="sm"
              steps={[
                %{name: "Conta", complete?: true, active?: false},
                %{name: "Workspace", complete?: false, active?: true}
              ]}
            />
          </div>

          <h1 class="text-2xl font-semibold tracking-tight text-gray-900 dark:text-white">
            Dê um nome ao seu workspace
          </h1>
          <p class="mt-2 mb-8 text-sm text-gray-600 dark:text-gray-400">
            É onde ficam os seus runners, projetos, pipelines e tarefas. Use o nome do time ou
            da empresa.
          </p>

          <.form for={@form} id="workspace-new-form" phx-change="validate" phx-submit="save">
            <.icon_field
              field={@form[:name]}
              icon="hero-building-office-2"
              label="Nome"
              placeholder="Acme Engenharia"
              required
              data-testid="workspace-new-name"
              phx-mounted={JS.focus()}
            />
            <.icon_field
              field={@form[:slug]}
              icon="hero-link"
              label="Endereço (opcional)"
              placeholder="acme-engenharia"
              help_text="Letras minúsculas, números e hífens. Sem preencher, vem do nome."
              data-testid="workspace-new-slug"
            />
            <p
              class="mb-6 text-sm text-gray-500 dark:text-gray-400"
              data-testid="workspace-new-slug-preview"
            >
              O endereço será
              <span class="font-mono text-gray-900 dark:text-white">/w/{@slug || "…"}</span>
            </p>
            <.button
              type="submit"
              class="w-full"
              size="lg"
              icon="hero-arrow-right"
              icon_placement="right"
              phx-disable-with="Criando…"
              data-testid="workspace-new-submit"
            >
              Criar workspace
            </.button>
          </.form>
        </div>
      </div>
    </Layouts.public>
    """
  end
end
