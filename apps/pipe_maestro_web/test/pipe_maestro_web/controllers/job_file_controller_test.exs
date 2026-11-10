defmodule PipeMaestroWeb.JobFileControllerTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Ecto.Query

  alias PipeMaestro.Jobs.{Files, JobFile}
  alias PipeMaestro.{Repo, Tasks, Workspaces}

  # A PNG of 1×1 pixel.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

  setup :register_and_log_in_member

  setup %{workspace: workspace, user: user} do
    {runner, _token} = runner_fixture(workspace, user)
    runner = with_directories(runner, [%{"name" => "app", "git" => true}])

    {:ok, task} =
      Tasks.create_task(user, workspace, %{
        "title" => "Tirar as screenshots",
        "prompt" => "Tire as screenshots da tela de login",
        "pipeline_id" => pipeline_fixture(workspace).id,
        "project_id" => project_fixture(runner, "app").id
      })

    [stage_run] = Tasks.get_task!(workspace, task.id).stage_runs
    %{runner: runner, job: stage_run.job}
  end

  defp store(ctx, path, content) do
    {:ok, file} = Files.store(ctx.runner, ctx.job.id, path, content)
    file
  end

  defp download(ctx, file), do: get(ctx.conn, "/w/#{ctx.workspace.slug}/files/#{file.id}")

  test "an image opens inline, with its type and no sniffing", ctx do
    conn = download(ctx, store(ctx, "telas/login.png", @png))

    assert response(conn, 200) == @png
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "image/png"
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~r/^inline;/
    assert disposition =~ "filename*=UTF-8''login.png"
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "sandbox"
    assert get_resp_header(conn, "cache-control") == ["private, max-age=3600"]
  end

  test "a CSV, an SVG and an HTML page are downloaded, never shown", ctx do
    for {path, content} <- [
          {"dados/r.csv", "a,b\n1,2\n"},
          {"grafico.svg", ~s(<svg xmlns="http://www.w3.org/2000/svg"></svg>)},
          {"relatorio.html", "<script>alert(1)</script>"}
        ] do
      conn = download(ctx, store(ctx, path, content))

      assert response(conn, 200) == content
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ~r/^attachment;/, path
    end
  end

  test "404 for another workspace's file or one that does not exist", ctx do
    file = store(ctx, "a.png", @png)

    other = workspace_fixture()
    stranger = member_fixture(other)

    assert build_conn()
           |> log_in_user(stranger)
           |> get("/w/#{ctx.workspace.slug}/files/#{file.id}")
           |> response(404)

    assert build_conn()
           |> log_in_user(stranger)
           |> get("/w/#{other.slug}/files/#{file.id}")
           |> response(404)

    assert ctx.conn
           |> get("/w/#{ctx.workspace.slug}/files/#{Ecto.UUID.generate()}")
           |> response(404)
  end

  test "asks to sign in when nobody is signed in", ctx do
    file = store(ctx, "a.png", @png)
    conn = get(build_conn(), "/w/#{ctx.workspace.slug}/files/#{file.id}")
    assert redirected_to(conn) =~ "/login"
  end

  test "410 for a file the retention emptied, with a plain message", ctx do
    {:ok, _} = Workspaces.update_workspace(ctx.workspace, %{job_files_retention_days: 1})
    file = store(ctx, "telas/login.png", @png)
    at = DateTime.add(DateTime.utc_now(:second), -2, :day)
    Repo.update_all(from(f in JobFile, where: f.id == ^file.id), set: [inserted_at: at])
    assert Files.prune(DateTime.utc_now()) == 1

    conn = download(ctx, file)
    assert response(conn, 410) =~ "removido pela retenção"
  end
end
