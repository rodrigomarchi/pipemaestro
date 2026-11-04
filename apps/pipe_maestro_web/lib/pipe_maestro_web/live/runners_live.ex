defmodule PipeMaestroWeb.RunnersLive do
  @moduledoc """
  The workspace's runners, with their status live: a runner turns online the
  moment it connects and offline the moment its connection drops. From here a
  member renames or revokes a runner and finds how to connect a new one.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.RunnerComponents

  alias Phoenix.Socket.Broadcast
  alias PipeMaestro.Audit
  alias PipeMaestro.Runners
  alias PipeMaestroWeb.{RunnerActions, RunnerStatus}

  @impl true
  def mount(_params, _session, socket) do
    workspace = socket.assigns.current_scope.workspace
    if connected?(socket), do: RunnerStatus.subscribe(workspace.id)

    {:ok,
     socket
     |> assign(page_title: "Executores", renaming: nil, rename_form: nil, connecting: false)
     |> assign(platform_url: PipeMaestroWeb.Endpoint.url())
     |> load_runners()}
  end

  @impl true
  def handle_info(%Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, load_runners(socket)}

  def handle_info(:runners_changed, socket), do: {:noreply, load_runners(socket)}

  @admin_events ~w(open_connect open_rename rename revoke)

  @impl true
  def handle_event(event, params, socket) when event in @admin_events do
    if can?(socket.assigns.current_scope, :manage_runners),
      do: admin_event(event, params, socket),
      else: {:noreply, put_flash(socket, :error, "Só admins do workspace gerenciam os runners.")}
  end

  def handle_event("close_connect", _params, socket),
    do: {:noreply, assign(socket, connecting: false)}

  def handle_event("close_rename", _params, socket),
    do: {:noreply, assign(socket, renaming: nil, rename_form: nil)}

  defp admin_event("open_connect", _params, socket),
    do: {:noreply, assign(socket, connecting: true)}

  defp admin_event("open_rename", %{"id" => id}, socket) do
    runner = Runners.get_runner!(socket.assigns.current_scope.workspace, id)

    {:noreply,
     assign(socket,
       renaming: runner,
       rename_form: to_form(Runners.change_runner_name(runner), as: "runner")
     )}
  end

  defp admin_event("rename", %{"runner" => params}, socket) do
    case Runners.rename_runner(socket.assigns.renaming, params) do
      {:ok, runner} ->
        RunnerStatus.notify_changed(runner.workspace_id)
        audit(socket, "runner.renamed", runner)

        {:noreply,
         socket
         |> put_flash(:info, "Runner renomeado para #{runner.name}.")
         |> assign(renaming: nil, rename_form: nil)
         |> load_runners()}

      {:error, changeset} ->
        {:noreply, assign(socket, rename_form: to_form(changeset, as: "runner"))}
    end
  end

  defp admin_event("revoke", %{"id" => id}, socket) do
    runner = Runners.get_runner!(socket.assigns.current_scope.workspace, id)
    runner = RunnerActions.revoke(socket.assigns.current_scope, runner)

    {:noreply,
     socket
     |> put_flash(:info, "Runner #{runner.name} revogado. A conexão foi encerrada.")
     |> load_runners()}
  end

  defp audit(socket, action, subject) do
    %{workspace: workspace, user: user} = socket.assigns.current_scope
    Audit.record(workspace, user, action, subject)
  end

  defp load_runners(socket) do
    workspace = socket.assigns.current_scope.workspace

    assign(socket,
      runners: Runners.list_runners(workspace),
      online: RunnerStatus.online_ids(workspace.id),
      now: DateTime.utc_now()
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:runners}
      title="Executores"
    >
      <:actions>
        <.button
          :if={can?(@current_scope, :manage_runners)}
          size="sm"
          icon="hero-plus"
          phx-click="open_connect"
          data-testid="connect-runner"
        >
          Conectar runner
        </.button>
      </:actions>

      <.card variant="outline">
        <.card_header
          title="Runners do workspace"
          description="Daemons na sua infraestrutura que executam as etapas do pipeline."
        >
          <:action>
            <.badge
              color="success"
              variant="soft"
              label={"#{MapSet.size(@online)} online"}
              data-testid="online-count"
            />
          </:action>
        </.card_header>

        <%!-- The card clips what overflows it: a narrow window scrolls the table instead. --%>
        <div :if={@runners != []} class="w-full overflow-x-auto">
          <.table id="runners" rows={@runners} row_id={&"runner-row-#{&1.id}"}>
            <:col :let={runner} label="Runner">
              <div class="flex items-center gap-2">
                <.icon name="hero-server" class="size-4 text-gray-400" />
                <.link
                  navigate={~p"/w/#{@current_scope.workspace.slug}/runners/#{runner.id}"}
                  class="font-medium text-gray-900 hover:underline dark:text-white"
                  data-testid={"runner-link-#{runner.name}"}
                >
                  <span data-testid={"runner-#{runner.name}"}>{runner.name}</span>
                </.link>
              </div>
              <p class="mt-0.5 font-mono text-xs text-gray-500 dark:text-gray-400">
                {runner.hostname} · {runner.os}/{runner.arch}
              </p>
              <p class="mt-0.5 text-xs text-gray-500 dark:text-gray-400">
                <.runner_version
                  runner={runner}
                  version_testid={"runner-version-#{runner.name}"}
                  outdated_testid={"runner-outdated-#{runner.name}"}
                />
              </p>
            </:col>
            <:col :let={runner} label="Status">
              <.runner_status
                online={MapSet.member?(@online, runner.id)}
                data-testid={"runner-status-#{runner.name}"}
              />
              <p
                :if={!MapSet.member?(@online, runner.id)}
                class="mt-1 whitespace-nowrap text-xs text-gray-500 dark:text-gray-400"
              >
                visto {time_ago(runner.last_seen_at, @now)}
              </p>
            </:col>
            <:col :let={runner} label="Labels">
              <div class="flex flex-wrap gap-1" data-testid={"runner-labels-#{runner.name}"}>
                <.badge
                  :for={label <- runner.labels}
                  size="xs"
                  color="gray"
                  variant="outline"
                  label={label}
                />
              </div>
            </:col>
            <:col :let={runner} label="Diretórios">
              <span
                :if={runner.directories != []}
                class="text-gray-600 dark:text-gray-300"
                data-testid={"runner-directories-#{runner.name}"}
              >
                {length(runner.directories)}
              </span>
              <.badge
                :if={runner.directories == []}
                size="xs"
                color="warning"
                variant="soft"
                label="sem raiz"
                data-testid={"runner-directories-#{runner.name}"}
              />
            </:col>
            <:col :let={runner} label="Agente">
              <span
                class="flex flex-wrap items-center gap-1.5 text-gray-600 dark:text-gray-300"
                data-testid={"runner-agent-#{runner.name}"}
              >
                <span :if={!runner.agent}>—</span>
                <span :if={runner.agent} class="font-mono text-xs">
                  {runner.agent["cli_version"] || "sem claude"}
                </span>
                <.badge
                  :if={runner.agent && runner.agent["auth"] == "login"}
                  size="xs"
                  color="warning"
                  variant="soft"
                  label="login pessoal"
                />
                <.badge
                  :if={runner.agent && runner.agent["auth"] == "api_key"}
                  size="xs"
                  color="success"
                  variant="soft"
                  label="chave de API"
                />
              </span>
            </:col>
            <:col :let={runner} label="Worktrees">
              <span
                class="text-gray-600 dark:text-gray-300"
                data-testid={"runner-worktrees-#{runner.name}"}
              >
                {worktree_usage(runner.worktree_usage)}
              </span>
            </:col>
            <:col :let={runner} label="Capacidade">
              <span data-testid={"runner-capacity-#{runner.name}"}>{runner.capacity}</span>
            </:col>
            <:col :let={runner} label="" class="text-right">
              <div
                :if={can?(@current_scope, :manage_runners)}
                class="flex justify-end gap-1 whitespace-nowrap"
              >
                <.button
                  size="xs"
                  variant="ghost"
                  color="gray"
                  icon="hero-pencil-square"
                  phx-click="open_rename"
                  phx-value-id={runner.id}
                  data-testid={"runner-rename-#{runner.name}"}
                >
                  Renomear
                </.button>
                <.button
                  size="xs"
                  variant="ghost"
                  color="danger"
                  icon="hero-no-symbol"
                  phx-click="revoke"
                  phx-value-id={runner.id}
                  data-confirm={"Revogar #{runner.name}? O token deixa de valer e a conexão cai."}
                  data-testid={"runner-revoke-#{runner.name}"}
                >
                  Revogar
                </.button>
              </div>
            </:col>
          </.table>
        </div>

        <.card_content :if={@runners == []}>
          <.empty
            data-testid="no-runners"
            title="Nenhum runner conectado ainda"
            description="Runners rodam na sua infraestrutura e se conectam a este workspace."
          >
            <:icon><.icon name="hero-server-stack" /></:icon>
            <:actions>
              <.button icon="hero-plus" phx-click="open_connect">Conectar runner</.button>
            </:actions>
          </.empty>
        </.card_content>
      </.card>

      <.modal
        :if={@connecting}
        id="connect-modal"
        title="Conectar um runner"
        max_width="lg"
        on_cancel={JS.push("close_connect")}
      >
        <.connect_instructions url={@platform_url} />
      </.modal>

      <.modal
        :if={@renaming}
        id="rename-modal"
        title={"Renomear #{@renaming.name}"}
        on_cancel={JS.push("close_rename")}
      >
        <.form for={@rename_form} id="rename-form" phx-submit="rename">
          <.icon_field
            field={@rename_form[:name]}
            icon="hero-tag"
            label="Nome"
            data-testid="rename-name"
          />
          <div class="flex justify-end gap-2">
            <.button type="button" variant="ghost" color="gray" phx-click="close_rename">
              Cancelar
            </.button>
            <.button type="submit" data-testid="rename-submit">Salvar</.button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end

  defp worktree_usage(nil), do: "—"

  defp worktree_usage(%{"count" => count, "bytes" => bytes} = usage) do
    free = if usage["free_bytes"], do: " (#{format_bytes(usage["free_bytes"])} livres)", else: ""
    "#{count} · #{format_bytes(bytes)}#{free}"
  end
end
