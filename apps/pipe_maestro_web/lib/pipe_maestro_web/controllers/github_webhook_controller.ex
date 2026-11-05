defmodule PipeMaestroWeb.GithubWebhookController do
  @moduledoc """
  The GitHub webhook of a workspace (`POST /api/github/webhook/<workspace>`):
  when an issue gets a project's trigger label
  (`PipeMaestro.Projects.Project`), it starts a task from the issue on the
  project's runner (or has the agent write it first, with the trigger mode
  `"triage"`). With the runner offline, the work waits for it; a project
  without a runner refuses the issue.

  Every delivery is signed with the workspace's secret
  `GITHUB_WEBHOOK_SECRET` (`PipeMaestro.Secrets`); an unsigned or
  badly signed one is refused. Other events and labels are acknowledged and
  ignored.
  """
  use PipeMaestroWeb, :controller

  alias PipeMaestro.{Projects, Proposals, Secrets, Tasks, Workspaces}

  @no_runner "o projeto precisa de um runner"

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
         false <- Tasks.active_for_issue?(workspace, issue["html_url"]),
         false <- Proposals.triaging?(workspace, issue["html_url"]) do
      start_task(conn, workspace, project, issue)
    else
      _not_for_us -> json(conn, %{ignored: "sem gatilho para esta issue"})
    end
  end

  defp handle(conn, _workspace, _event, _params), do: json(conn, %{ignored: "evento sem uso"})

  defp start_task(conn, _workspace, %{runner_id: nil}, _issue), do: refuse(conn, @no_runner)

  defp start_task(conn, workspace, %{trigger_mode: "triage"} = project, issue) do
    case Proposals.triage_issue(workspace, project, issue) do
      {:ok, job} ->
        conn |> put_status(201) |> json(%{proposal_id: job.id})

      {:error, :already_triaging} ->
        json(conn, %{ignored: "a issue já está em triagem"})

      {:error, reason} ->
        refuse(conn, "a triagem não pôde começar: " <> reason_text(reason))
    end
  end

  defp start_task(conn, workspace, project, issue) do
    case Tasks.create_from_issue(workspace, project, issue) do
      {:ok, task} -> conn |> put_status(201) |> json(%{task_id: task.id})
      {:error, reason} -> refuse(conn, "a tarefa não pôde começar: " <> reason_text(reason))
    end
  end

  defp refuse(conn, message), do: conn |> put_status(422) |> json(%{error: message})

  defp reason_text(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field}: #{&1}") end)
    |> Enum.join("; ")
  end

  defp reason_text(reason), do: inspect(reason)
end
