defmodule PipeMaestroWeb.IntegrationLive.Show do
  @moduledoc """
  One connection to a git host: its status, the webhook's address and secret
  for a manual setup, and its linked repositories, with the search that
  links a new one to a project.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.IntegrationComponents

  alias PipeMaestro.{Integrations, Projects}
  alias PipeMaestro.Integrations.Connection
  alias PipeMaestroWeb.IntegrationOAuth

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    if can?(scope, :manage_integrations) do
      connection = Integrations.get_connection!(scope.workspace, id)

      {:ok,
       socket
       |> assign(
         page_title: connection.name,
         connection: connection,
         projects: Projects.list_projects(scope.workspace),
         show_secret: false,
         linking: false
       )
       |> reset_link()
       |> load_repos()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Só admins do workspace gerenciam as integrações.")
       |> push_navigate(to: ~p"/w/#{scope.workspace.slug}")}
    end
  end

  defp load_repos(socket),
    do: assign(socket, repos: Integrations.list_repos(socket.assigns.connection))

  defp reset_link(socket) do
    assign(socket,
      search: "",
      results: [],
      search_error: nil,
      picked: nil,
      link_form: to_form(%{"full_name" => "", "project_id" => ""}, as: "repo")
    )
  end

  @impl true
  def handle_event("check", _params, socket) do
    connection = Integrations.check_connection(socket.assigns.connection)

    socket =
      case connection.status do
        "active" -> put_flash(socket, :info, "O host respondeu, como #{connection.bot_login}.")
        _error -> put_flash(socket, :error, "O host recusou: #{connection.last_error}")
      end

    {:noreply, assign(socket, connection: connection)}
  end

  def handle_event("authorize", _params, socket) do
    url =
      IntegrationOAuth.authorize_url(socket.assigns.connection, socket.assigns.current_scope.user)

    {:noreply, redirect(socket, external: url)}
  end

  def handle_event("delete", _params, socket) do
    %{workspace: workspace, user: user} = socket.assigns.current_scope
    :ok = Integrations.delete_connection(socket.assigns.connection, user)

    {:noreply,
     socket
     |> put_flash(:info, "Conexão #{socket.assigns.connection.name} removida.")
     |> push_navigate(to: ~p"/w/#{workspace.slug}/integrations")}
  end

  def handle_event("toggle_secret", _params, socket),
    do: {:noreply, update(socket, :show_secret, &(!&1))}

  def handle_event("rotate_secret", _params, socket) do
    %{connection: connection, current_scope: %{user: user}} = socket.assigns

    case Integrations.rotate_webhook_secret(connection, user, webhook_url(connection)) do
      {:ok, connection} ->
        {:noreply,
         socket
         |> assign(connection: connection, show_secret: true)
         |> put_flash(:info, "Segredo novo. Os webhooks criados pela plataforma já usam ele.")}

      {:error, message} ->
        {:noreply,
         socket
         |> assign(
           connection:
             Integrations.get_connection!(socket.assigns.current_scope.workspace, connection.id)
         )
         |> put_flash(:error, message)}
    end
  end

  def handle_event("open_link", _params, socket),
    do: {:noreply, socket |> reset_link() |> assign(linking: true) |> search("")}

  def handle_event("close_link", _params, socket),
    do: {:noreply, socket |> reset_link() |> assign(linking: false)}

  def handle_event("search", %{"search" => %{"query" => query}}, socket),
    do: {:noreply, search(socket, query)}

  def handle_event("pick", %{"full-name" => full_name}, socket) do
    {:noreply,
     assign(socket,
       picked: full_name,
       link_form: to_form(%{"full_name" => full_name, "project_id" => ""}, as: "repo")
     )}
  end

  def handle_event("link", %{"repo" => params}, socket) do
    %{connection: connection, current_scope: %{user: user, workspace: workspace}} = socket.assigns

    case Integrations.link_repo(connection, user, params, webhook_url(connection)) do
      {:ok, repo} ->
        {:noreply,
         socket
         |> put_flash(:info, link_message(repo))
         |> push_navigate(
           to: ~p"/w/#{workspace.slug}/integrations/#{connection.id}/repos/#{repo.id}"
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, link_form: to_form(changeset, as: "repo"))}
    end
  end

  defp link_message(%{webhook_status: "managed", full_name: name}),
    do: "#{name} vinculado. O webhook já foi criado; agora defina os gatilhos."

  defp link_message(%{full_name: name}),
    do:
      "#{name} vinculado. Crie o webhook com a URL e o segredo desta conexão; agora defina os gatilhos."

  defp search(socket, query) do
    case Integrations.available_repos(socket.assigns.connection, query) do
      {:ok, repos, _more?} ->
        linked = MapSet.new(socket.assigns.repos, & &1.full_name)

        assign(socket,
          search: query,
          results: Enum.reject(repos, &MapSet.member?(linked, &1.full_name)),
          search_error: nil
        )

      {:error, message} ->
        assign(socket, search: query, results: [], search_error: message)
    end
  end

  defp webhook_status(assigns) do
    {color, label} =
      case assigns.repo.webhook_status do
        "managed" -> {"success", "webhook criado"}
        "failed" -> {"danger", "webhook falhou"}
        _manual -> {"warning", "webhook manual"}
      end

    assigns = assign(assigns, color: color, label: label)

    ~H"""
    <.badge size="xs" color={@color} variant="soft" label={@label} data-testid={@testid} />
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:integrations}
      title={@connection.name}
    >
      <:actions>
        <.button
          size="sm"
          variant="outline"
          color="gray"
          icon="hero-signal"
          phx-click="check"
          data-testid="integration-check"
        >
          Testar
        </.button>
        <.button
          size="sm"
          variant="outline"
          color="gray"
          icon="hero-pencil-square"
          link_type="live_redirect"
          to={~p"/w/#{@current_scope.workspace.slug}/integrations/#{@connection.id}/edit"}
          data-testid="integration-edit"
        >
          Editar
        </.button>
        <.button
          size="sm"
          variant="ghost"
          color="danger"
          icon="hero-trash"
          phx-click="delete"
          data-confirm={"Remover a conexão #{@connection.name}? Os webhooks criados pela plataforma também saem."}
          data-testid="integration-delete"
        >
          Remover
        </.button>
      </:actions>

      <div class="space-y-6">
        <.card variant="outline">
          <.card_content>
            <div class="flex flex-wrap items-start justify-between gap-4">
              <div class="min-w-0 space-y-1 text-sm">
                <p class="text-gray-500 dark:text-gray-400">
                  {provider_name(@connection.provider)} ·
                  <span class="break-all">{@connection.base_url}</span>
                </p>
                <p class="text-gray-900 dark:text-white" data-testid="integration-bot">
                  <span :if={@connection.bot_login}>
                    Age como <strong>{@connection.bot_login}</strong>
                  </span>
                  <span :if={!@connection.bot_login}>Ainda sem acesso verificado.</span>
                  <span :if={@connection.server_version} class="text-gray-500 dark:text-gray-400">
                    · versão {@connection.server_version}
                  </span>
                </p>
                <p class="text-gray-500 dark:text-gray-400">
                  {auth_name(@connection.auth_kind)} · {api_mode_name(@connection.api_mode)}
                </p>
                <p
                  :if={@connection.status == "error"}
                  class="text-danger-600 dark:text-danger-400"
                  data-testid="integration-error"
                >
                  {@connection.last_error}
                </p>
              </div>
              <div class="flex flex-col items-end gap-2">
                <.integration_status connection={@connection} data-testid="integration-status" />
                <.button
                  :if={@connection.auth_kind == "oauth"}
                  size="xs"
                  icon="hero-arrow-top-right-on-square"
                  phx-click="authorize"
                  data-testid="integration-oauth-connect"
                >
                  {if @connection.status == "active",
                    do: "Autorizar de novo",
                    else: "Autorizar no Forgejo"}
                </.button>
              </div>
            </div>
          </.card_content>
        </.card>

        <.card variant="outline">
          <.card_header
            title="Repositórios vinculados"
            description="Cada um ligado a um projeto: as issues viram tarefas no diretório dele."
          >
            <:action>
              <.button
                :if={!@linking}
                size="xs"
                icon="hero-plus"
                phx-click="open_link"
                data-testid="repo-link-open"
              >
                Vincular repositório
              </.button>
            </:action>
          </.card_header>
          <.card_content>
            <div
              :if={@linking}
              class="mb-6 space-y-4 rounded-xl border border-primary-200 p-4 dark:border-primary-900"
              data-testid="repo-link"
            >
              <.form
                :let={f}
                for={to_form(%{"query" => @search}, as: "search")}
                id="repo-search-form"
                phx-change="search"
                phx-submit="search"
              >
                <.icon_field
                  field={f[:query]}
                  icon="hero-magnifying-glass"
                  label="Buscar no Forgejo"
                  placeholder="dono/repositório"
                  phx-debounce="300"
                  data-testid="repo-search"
                />
              </.form>
              <p :if={@search_error} class="text-sm text-danger-600 dark:text-danger-400">
                {@search_error}
              </p>
              <ul
                :if={@picked == nil}
                class="max-h-64 divide-y divide-gray-100 overflow-y-auto text-sm dark:divide-gray-800"
              >
                <li
                  :if={@results == [] and !@search_error}
                  class="py-2 text-gray-500 dark:text-gray-400"
                >
                  Nenhum repositório encontrado.
                </li>
                <li :for={repo <- @results} class="flex items-center justify-between gap-3 py-2">
                  <span class="font-mono text-gray-900 dark:text-white">{repo.full_name}</span>
                  <.button
                    size="xs"
                    variant="outline"
                    color="gray"
                    phx-click="pick"
                    phx-value-full-name={repo.full_name}
                    data-testid={"repo-option-#{key(repo.full_name)}"}
                  >
                    Escolher
                  </.button>
                </li>
              </ul>
              <.form
                :if={@picked}
                for={@link_form}
                id="repo-link-form"
                phx-submit="link"
                class="space-y-4"
              >
                <input type="hidden" name="repo[full_name]" value={@picked} />
                <p class="text-sm text-gray-600 dark:text-gray-300" data-testid="repo-picked">
                  <.icon name="hero-code-bracket-square" class="size-4 text-primary-500" />
                  <span class="font-mono">{@picked}</span>
                </p>
                <p
                  :for={{message, _} <- Keyword.get_values(@link_form.errors, :full_name)}
                  class="text-sm text-danger-600 dark:text-danger-400"
                >
                  {message}
                </p>
                <.icon_field
                  field={@link_form[:project_id]}
                  icon="hero-folder"
                  type="select"
                  label="Projeto"
                  prompt="Escolha o projeto (o diretório do runner)"
                  options={Enum.map(@projects, &{"#{&1.name} (#{&1.directory})", &1.id})}
                  data-testid="repo-project"
                />
                <div class="flex justify-end gap-2">
                  <.button type="button" size="sm" variant="ghost" color="gray" phx-click="close_link">
                    Cancelar
                  </.button>
                  <.button size="sm" icon="hero-link" data-testid="repo-link-save">Vincular</.button>
                </div>
              </.form>
              <div :if={!@picked} class="flex justify-end">
                <.button type="button" size="sm" variant="ghost" color="gray" phx-click="close_link">
                  Cancelar
                </.button>
              </div>
            </div>

            <p
              :if={@repos == [] and !@linking}
              class="text-sm text-gray-500 dark:text-gray-400"
              data-testid="no-repos"
            >
              Nenhum repositório vinculado ainda.
            </p>
            <ul :if={@repos != []} class="divide-y divide-gray-100 text-sm dark:divide-gray-800">
              <li
                :for={repo <- @repos}
                class="flex flex-wrap items-center justify-between gap-3 py-3"
                data-testid={"repo-#{key(repo.full_name)}"}
              >
                <div class="min-w-0">
                  <.link
                    navigate={
                      ~p"/w/#{@current_scope.workspace.slug}/integrations/#{@connection.id}/repos/#{repo.id}"
                    }
                    class="font-mono font-medium text-gray-900 hover:underline dark:text-white"
                    data-testid={"repo-link-#{key(repo.full_name)}"}
                  >
                    {repo.full_name}
                  </.link>
                  <p class="mt-0.5 text-xs text-gray-500 dark:text-gray-400">
                    {if repo.project, do: "projeto #{repo.project.name}", else: "sem projeto"} · {length(
                      repo.triggers
                    )} gatilhos
                  </p>
                </div>
                <.webhook_status repo={repo} testid={"repo-webhook-#{key(repo.full_name)}"} />
              </li>
            </ul>
          </.card_content>
        </.card>

        <.card variant="outline">
          <.card_header
            title="Webhook"
            description="Para um repositório sem webhook criado pela plataforma: no Forgejo, Configurações → Webhooks → Forgejo, content type JSON, eventos de issues, comentários e pull requests."
          />
          <.card_content>
            <dl class="grid gap-3 text-sm sm:grid-cols-[8rem_1fr]">
              <dt class="text-gray-500 dark:text-gray-400">URL</dt>
              <dd
                class="break-all font-mono text-gray-900 dark:text-white"
                data-testid="integration-webhook-url"
              >
                {webhook_url(@connection)}
              </dd>
              <dt class="text-gray-500 dark:text-gray-400">Segredo</dt>
              <dd class="flex flex-wrap items-center gap-2">
                <span
                  class="break-all font-mono text-gray-900 dark:text-white"
                  data-testid="integration-webhook-secret"
                >
                  {if @show_secret, do: Connection.webhook_secret(@connection), else: "••••••••••••"}
                </span>
                <.button
                  size="xs"
                  variant="ghost"
                  color="gray"
                  icon={if @show_secret, do: "hero-eye-slash", else: "hero-eye"}
                  phx-click="toggle_secret"
                  data-testid="integration-webhook-secret-reveal"
                >
                  {if @show_secret, do: "Esconder", else: "Mostrar"}
                </.button>
                <.button
                  size="xs"
                  variant="ghost"
                  color="warning"
                  icon="hero-arrow-path"
                  phx-click="rotate_secret"
                  data-confirm="Gerar um segredo novo? Webhooks criados à mão precisam ser atualizados."
                  data-testid="integration-webhook-secret-rotate"
                >
                  Gerar outro
                </.button>
              </dd>
            </dl>
          </.card_content>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
