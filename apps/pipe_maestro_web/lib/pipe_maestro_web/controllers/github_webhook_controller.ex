defmodule PipeMaestroWeb.GithubWebhookController do
  @moduledoc """
  The GitHub webhook of a workspace (`POST /api/github/webhook/<workspace>`):
  when an issue gets a project's trigger label
  (`PipeMaestro.Projects.Project`), it starts a task from the issue on
  an online runner that offers the project's directory.

  Every delivery is signed with the workspace's secret
  `GITHUB_WEBHOOK_SECRET` (`PipeMaestro.Secrets`); an unsigned or
  badly signed one is refused. Other events and labels are acknowledged and
  ignored.
  """
  use PipeMaestroWeb, :controller

  alias PipeMaestro.{Projects, Runners, Secrets, Tasks, Workspaces}
  alias PipeMaestroWeb.RunnerStatus

  @doc "Takes one delivery."
  @spec receive_event(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def receive_event(conn, %{"workspace_slug" => slug} = params) do
    with %{} = workspace <- Workspaces.get_workspace_by_slug(slug),
         secret when is_binary(secret) <- Secrets.env(workspace)["GITHUB_WEBHOOK_SECRET"],
         :ok <- verify(conn, secret) do
      handle(conn, workspace, get_req_header(conn, "x-github-event"), params)
    else
      :bad_signature -> conn |> put_status(401) |> json(%{error: "assinatura inválida"})
      _missing -> conn |> put_status(404) |> json(%{error: "webhook não configurado"})
    end
  end

  defp verify(conn, secret) do
    expected =
      "sha256=" <>
        Base.encode16(:crypto.mac(:hmac, :sha256, secret, conn.assigns[:raw_body] || ""),
          case: :lower
        )

    case get_req_header(conn, "x-hub-signature-256") do
      [signature] ->
        if Plug.Crypto.secure_compare(signature, expected), do: :ok, else: :bad_signature

      _none ->
        :bad_signature
    end
  end

  defp handle(conn, _workspace, ["ping"], _params), do: json(conn, %{pong: true})

  defp handle(conn, workspace, ["issues"], %{"action" => "labeled"} = params) do
    with %{} = project <-
           Projects.for_repo(workspace, get_in(params, ["repository", "full_name"]) || ""),
         true <- params["label"]["name"] == project.trigger_label,
         issue = params["issue"],
         false <- Tasks.active_for_issue?(workspace, issue["html_url"]) do
      start_task(conn, workspace, project, issue)
    else
      _not_for_us -> json(conn, %{ignored: "sem gatilho para esta issue"})
    end
  end

  defp handle(conn, _workspace, _event, _params), do: json(conn, %{ignored: "evento sem uso"})

  defp start_task(conn, workspace, project, issue) do
    online = RunnerStatus.online_ids(workspace.id)

    runner =
      workspace
      |> Runners.list_runners()
      |> Enum.find(fn runner ->
        MapSet.member?(online, runner.id) and
          Enum.any?(runner.directories, &(&1["name"] == project.directory))
      end)

    with %{} <- runner,
         {:ok, task} <- Tasks.create_from_issue(workspace, project, issue, runner.id) do
      conn |> put_status(201) |> json(%{task_id: task.id})
    else
      nil ->
        conn
        |> put_status(422)
        |> json(%{error: "nenhum runner online oferece o diretório #{project.directory}"})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: "a tarefa não pôde começar: #{inspect(reason)}"})
    end
  end
end
