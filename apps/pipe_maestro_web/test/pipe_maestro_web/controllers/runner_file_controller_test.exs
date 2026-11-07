defmodule PipeMaestroWeb.RunnerFileControllerTest do
  use PipeMaestroWeb.ConnCase, async: true

  alias PipeMaestro.{Repo, Runners, Tasks}
  alias PipeMaestro.Jobs.{Files, JobFile}
  alias PipeMaestroProtocol.JobFiles

  # A PNG of 1×1 pixel.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    {runner, token} = runner_fixture(workspace, user)
    runner = with_directories(runner, [%{"name" => "app", "git" => true}])

    {:ok, task} =
      Tasks.create_task(user, workspace, %{
        "title" => "Tirar as screenshots",
        "prompt" => "Tire as screenshots da tela de login",
        "pipeline_id" => pipeline_fixture(workspace).id,
        "project_id" => project_fixture(runner, "app").id
      })

    [stage_run] = Tasks.get_task!(workspace, task.id).stage_runs

    %{
      workspace: workspace,
      user: user,
      runner: runner,
      token: token,
      stage_run: stage_run,
      job: stage_run.job
    }
  end

  defp upload(conn, token, job_id, path, body, content_type \\ "application/octet-stream") do
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn

    conn
    |> put_req_header("content-type", content_type)
    |> put("/api/runner/jobs/#{job_id}/files?" <> URI.encode_query(%{"path" => path}), body)
  end

  test "keeps the file, tied to the job and its stage run", ctx do
    body = ctx.conn |> upload(ctx.token, ctx.job.id, "a.png", @png) |> json_response(201)

    assert body == %{
             "path" => "a.png",
             "byte_size" => byte_size(@png),
             "sha256" => Base.encode16(:crypto.hash(:sha256, @png), case: :lower),
             "content_type" => "image/png"
           }

    assert %{"content_type" => "text/csv", "path" => "dados/r.csv"} =
             build_conn()
             |> upload(ctx.token, ctx.job.id, "dados/r.csv", "a,b\n1,2\n")
             |> json_response(201)

    files = Files.list_for_stage_run(ctx.stage_run)
    assert Enum.map(files, & &1.path) == ["a.png", "dados/r.csv"]
    assert Enum.all?(files, &(&1.job_id == ctx.job.id and &1.stage_run_id == ctx.stage_run.id))
  end

  test "sending the same path again replaces the file", ctx do
    ctx.conn |> upload(ctx.token, ctx.job.id, "dados/r.csv", "velho") |> json_response(201)

    assert %{"byte_size" => 4} =
             build_conn()
             |> upload(ctx.token, ctx.job.id, "dados/r.csv", "novo")
             |> json_response(201)

    assert [%{__struct__: JobFile, byte_size: 4}] = Repo.all(JobFile)
  end

  test "401 without a token, with an invalid one or for a revoked runner", ctx do
    assert ctx.conn |> upload(nil, ctx.job.id, "a.png", @png) |> response(401)
    assert build_conn() |> upload("cpr_invalido", ctx.job.id, "a.png", @png) |> response(401)

    {:ok, _} = Runners.revoke_runner(ctx.runner)
    assert build_conn() |> upload(ctx.token, ctx.job.id, "a.png", @png) |> response(401)
    assert Repo.all(JobFile) == []
  end

  test "404 for another runner's job or one that does not exist, alike", ctx do
    {_other, other_token} = runner_fixture(ctx.workspace, ctx.user)

    assert %{"error" => "not_found"} =
             ctx.conn |> upload(other_token, ctx.job.id, "a.png", @png) |> json_response(404)

    assert %{"error" => "not_found"} =
             build_conn()
             |> upload(ctx.token, Ecto.UUID.generate(), "a.png", @png)
             |> json_response(404)

    assert Repo.all(JobFile) == []
  end

  test "413 above the limit of a file", ctx do
    too_big = :binary.copy("a", JobFiles.max_file_bytes() + 1)

    assert %{"error" => "too_large", "limit" => limit} =
             ctx.conn
             |> upload(ctx.token, ctx.job.id, "grande.bin", too_big)
             |> json_response(413)

    assert limit == JobFiles.max_file_bytes()
    assert Repo.all(JobFile) == []
  end

  test "413 once the job has as many files as it may", ctx do
    for n <- 1..JobFiles.max_files() do
      {:ok, _} = Files.store(ctx.runner, ctx.job.id, "f-#{n}.txt", "x")
    end

    assert %{"error" => "too_large"} =
             ctx.conn |> upload(ctx.token, ctx.job.id, "mais.txt", "x") |> json_response(413)
  end

  test "422 for a path that would escape the job's folder", ctx do
    for path <- ["../x", "/etc/x", "a/../../b", ""] do
      assert %{"error" => "invalid_path"} =
               build_conn() |> upload(ctx.token, ctx.job.id, path, "x") |> json_response(422)
    end

    assert Repo.all(JobFile) == []
  end

  test "415 for a body that is not application/octet-stream", ctx do
    assert ctx.conn
           |> upload(ctx.token, ctx.job.id, "a.json", ~s({"a": 1}), "application/json")
           |> response(415)

    assert Repo.all(JobFile) == []
  end
end
