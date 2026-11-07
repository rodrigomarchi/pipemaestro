defmodule PipeMaestro.Jobs.FilesTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.Jobs.{Files, JobFile}
  alias PipeMaestro.{Repo, Tasks}
  alias PipeMaestroProtocol.JobFiles

  # A PNG of 1×1 pixel.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    {runner, _token} = runner_fixture(workspace, user)
    runner = with_directories(runner, [%{"name" => "app", "git" => true}])

    {:ok, task} =
      Tasks.create_task(user, workspace, %{
        "title" => "Tirar as screenshots",
        "prompt" => "Tire as screenshots da tela de login",
        "pipeline_id" => pipeline_fixture(workspace).id,
        "project_id" => project_fixture(runner, "app").id
      })

    task = Tasks.get_task!(workspace, task.id)
    [stage_run] = task.stage_runs

    %{
      workspace: workspace,
      user: user,
      runner: runner,
      task: task,
      stage_run: stage_run,
      job: stage_run.job
    }
  end

  describe "store/4" do
    test "keeps the file of the runner's job, tied to its stage run", ctx do
      assert {:ok, %{__struct__: JobFile} = file} =
               Files.store(ctx.runner, ctx.job.id, "a.png", @png)

      assert file.path == "a.png"
      assert file.content_type == "image/png"
      assert file.byte_size == byte_size(@png)
      assert file.sha256 == Base.encode16(:crypto.hash(:sha256, @png), case: :lower)
      assert file.job_id == ctx.job.id
      assert file.stage_run_id == ctx.stage_run.id
      assert file.workspace_id == ctx.workspace.id

      assert {:ok, %{__struct__: JobFile, content_type: "text/csv", path: "dados/r.csv"}} =
               Files.store(ctx.runner, ctx.job.id, "dados/r.csv", "a,b\n1,2\n")

      assert {:ok, %{__struct__: JobFile, content_type: "application/octet-stream"}} =
               Files.store(ctx.runner, ctx.job.id, "saida.desconhecida", "x")
    end

    test "sending the same path again replaces the file, without a second row", ctx do
      {:ok, first} = Files.store(ctx.runner, ctx.job.id, "dados/r.csv", "a,b\n")
      {:ok, second} = Files.store(ctx.runner, ctx.job.id, "dados/r.csv", "a,b\n1,2\n")

      assert second.id == first.id
      assert second.byte_size == 8
      assert [%{__struct__: JobFile}] = Repo.all(JobFile)

      assert %{__struct__: JobFile, content: "a,b\n1,2\n"} =
               Files.get_for_download(ctx.workspace, first.id)
    end

    test "another runner's job, or one that does not exist, is not found", ctx do
      {other_runner, _token} = runner_fixture(ctx.workspace, ctx.user)

      assert Files.store(other_runner, ctx.job.id, "a.png", @png) == {:error, :not_found}
      assert Files.store(ctx.runner, Ecto.UUID.generate(), "a.png", @png) == {:error, :not_found}
      assert Files.store(ctx.runner, "not-a-uuid", "a.png", @png) == {:error, :not_found}
      assert Repo.all(JobFile) == []
    end

    test "a path that would escape the job's folder is refused", ctx do
      for path <- ["../x", "/etc/passwd", "./a", "a//b", ""] do
        assert Files.store(ctx.runner, ctx.job.id, path, "x") == {:error, :invalid_path}
      end

      assert Repo.all(JobFile) == []
    end

    test "a file above the limit is refused", ctx do
      too_big = :binary.copy("a", JobFiles.max_file_bytes() + 1)

      assert Files.store(ctx.runner, ctx.job.id, "grande.bin", too_big) ==
               {:error, :too_large}

      assert Repo.all(JobFile) == []
    end

    test "the job's total is limited, not counting the file being replaced", ctx do
      chunk = :binary.copy("a", JobFiles.max_file_bytes())
      count = div(JobFiles.max_job_bytes(), JobFiles.max_file_bytes())

      for n <- 1..count do
        assert {:ok, _} = Files.store(ctx.runner, ctx.job.id, "parte-#{n}.bin", chunk)
      end

      assert Files.store(ctx.runner, ctx.job.id, "mais.bin", "x") == {:error, :too_large}
      assert {:ok, _} = Files.store(ctx.runner, ctx.job.id, "parte-1.bin", chunk)
    end

    test "the job's number of files is limited, not counting the file being replaced", ctx do
      for n <- 1..JobFiles.max_files() do
        assert {:ok, _} = Files.store(ctx.runner, ctx.job.id, "f-#{n}.txt", "x")
      end

      assert Files.store(ctx.runner, ctx.job.id, "um-a-mais.txt", "x") == {:error, :too_large}
      assert {:ok, _} = Files.store(ctx.runner, ctx.job.id, "f-1.txt", "y")
    end
  end

  describe "listing" do
    test "a stage run's files, by path, without their content", ctx do
      {:ok, _} = Files.store(ctx.runner, ctx.job.id, "dados/r.csv", "a,b\n")
      {:ok, _} = Files.store(ctx.runner, ctx.job.id, "a.png", @png)

      assert [
               %{__struct__: JobFile, path: "a.png", content: nil},
               %{__struct__: JobFile, path: "dados/r.csv", content: nil}
             ] =
               Files.list_for_stage_run(ctx.stage_run)
    end

    test "a task's files, grouped by stage run, without their content", ctx do
      {:ok, _} = Files.store(ctx.runner, ctx.job.id, "a.png", @png)
      stage_run_id = ctx.stage_run.id

      assert %{^stage_run_id => [%{__struct__: JobFile, path: "a.png", content: nil}]} =
               Files.list_for_task(ctx.task)

      other_task = Tasks.get_task!(ctx.workspace, ctx.task.id)
      assert map_size(Files.list_for_task(%{other_task | id: Ecto.UUID.generate()})) == 0
    end
  end

  describe "get_for_download/2" do
    test "the workspace's file, with its content; nothing for another workspace", ctx do
      {:ok, file} = Files.store(ctx.runner, ctx.job.id, "a.png", @png)

      assert %{__struct__: JobFile, content: @png, content_type: "image/png"} =
               Files.get_for_download(ctx.workspace, file.id)

      assert Files.get_for_download(workspace_fixture(), file.id) == nil
      assert Files.get_for_download(ctx.workspace, Ecto.UUID.generate()) == nil
      assert Files.get_for_download(ctx.workspace, "not-a-uuid") == nil
    end
  end

  test "image?/1: only raster images are shown inline" do
    for type <- ~w(image/png image/jpeg image/gif image/webp) do
      assert Files.image?(struct(JobFile, content_type: type)), type
    end

    for type <- ~w(image/svg+xml text/html text/csv application/octet-stream) do
      refute Files.image?(struct(JobFile, content_type: type)), type
    end
  end

  test "limits/0 come from the protocol" do
    assert Files.limits() == %{
             max_file_bytes: JobFiles.max_file_bytes(),
             max_job_bytes: JobFiles.max_job_bytes(),
             max_files: JobFiles.max_files()
           }
  end
end
