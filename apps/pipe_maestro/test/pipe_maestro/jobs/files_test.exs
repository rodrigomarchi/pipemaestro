defmodule PipeMaestro.Jobs.FilesTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  import Ecto.Query

  alias PipeMaestro.Jobs.{Files, Job, JobFile}
  alias PipeMaestro.{Repo, Tasks, Workspaces}
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

  @mib 1_048_576

  defp policy(ctx, attrs) do
    {:ok, workspace} = Workspaces.update_workspace(ctx.workspace, attrs)
    workspace
  end

  defp age_file(%{id: id}, days) do
    at = DateTime.add(DateTime.utc_now(:second), -days, :day)
    {1, _} = Repo.update_all(from(f in JobFile, where: f.id == ^id), set: [inserted_at: at])
  end

  defp kib(n), do: :binary.copy("a", n * 1024)

  describe "the workspace's quota" do
    test "refuses the file that would take the workspace past it", ctx do
      workspace = policy(ctx, %{job_files_quota_mib: 1})

      assert {:ok, _} = Files.store(ctx.runner, ctx.job.id, "a.bin", kib(600))

      assert Files.store(ctx.runner, ctx.job.id, "b.bin", kib(600)) ==
               {:error, :quota_exceeded}

      assert [%{path: "a.bin"}] = Repo.all(JobFile)
      assert Files.workspace_usage(workspace) == %{bytes: 600 * 1024, quota_bytes: @mib}
    end

    test "a file that fills it exactly fits", ctx do
      policy(ctx, %{job_files_quota_mib: 1})

      assert {:ok, _} = Files.store(ctx.runner, ctx.job.id, "a.bin", kib(512))
      assert {:ok, _} = Files.store(ctx.runner, ctx.job.id, "b.bin", kib(512))
      assert Files.store(ctx.runner, ctx.job.id, "c.bin", "x") == {:error, :quota_exceeded}
    end

    test "counts the refusal on the job, without changing its status", ctx do
      policy(ctx, %{job_files_quota_mib: 1})
      status = Repo.get!(Job, ctx.job.id).status

      assert {:ok, _} = Files.store(ctx.runner, ctx.job.id, "a.bin", kib(900))
      assert {:error, :quota_exceeded} = Files.store(ctx.runner, ctx.job.id, "b.bin", kib(900))
      assert {:error, :quota_exceeded} = Files.store(ctx.runner, ctx.job.id, "c.bin", kib(900))

      job = Repo.get!(Job, ctx.job.id)
      assert Map.get(job, :files_refused_quota) == 2
      assert job.status == status
    end

    test "replacing a path discounts the file it replaces", ctx do
      policy(ctx, %{job_files_quota_mib: 1})

      assert {:ok, _} = Files.store(ctx.runner, ctx.job.id, "a.bin", kib(900))
      assert {:ok, _} = Files.store(ctx.runner, ctx.job.id, "a.bin", kib(1000))
      assert [%{byte_size: 1_024_000}] = Repo.all(JobFile)
    end

    test "files the retention emptied do not count", ctx do
      policy(ctx, %{job_files_quota_mib: 1, job_files_retention_days: 10})

      {:ok, old} = Files.store(ctx.runner, ctx.job.id, "velho.bin", kib(900))
      age_file(old, 11)
      assert Files.prune(DateTime.utc_now()) == 1

      assert {:ok, _} = Files.store(ctx.runner, ctx.job.id, "novo.bin", kib(900))
    end

    test "counts the whole workspace, across jobs", ctx do
      workspace = policy(ctx, %{job_files_quota_mib: 1})
      other_job = job_fixture(ctx.runner, ctx.user)

      assert {:ok, _} = Files.store(ctx.runner, ctx.job.id, "a.bin", kib(700))

      assert Files.store(ctx.runner, other_job.id, "a.bin", kib(700)) ==
               {:error, :quota_exceeded}

      assert Files.workspace_usage(workspace).bytes == 700 * 1024
    end

    test "without a quota, only the job's limits apply", ctx do
      assert {:ok, _} = Files.store(ctx.runner, ctx.job.id, "a.bin", kib(2048))
      assert Files.workspace_usage(ctx.workspace) == %{bytes: 2048 * 1024, quota_bytes: nil}
      assert Files.workspace_usage(workspace_fixture()) == %{bytes: 0, quota_bytes: nil}
    end
  end

  describe "prune/2" do
    test "empties the files past their workspace's retention, keeping the row", ctx do
      policy(ctx, %{job_files_retention_days: 10})
      now = DateTime.utc_now(:second)

      {:ok, old} = Files.store(ctx.runner, ctx.job.id, "telas/velha.png", @png)
      {:ok, fresh} = Files.store(ctx.runner, ctx.job.id, "nova.csv", "a,b\n")
      age_file(old, 11)

      assert Files.prune(now) == 1
      assert Files.prune(now) == 0

      pruned = Files.get_for_download(ctx.workspace, old.id)
      assert pruned.content == nil
      assert %DateTime{} = Map.get(pruned, :pruned_at)
      assert pruned.path == "telas/velha.png"
      assert pruned.byte_size == byte_size(@png)
      assert pruned.content_type == "image/png"

      kept = Files.get_for_download(ctx.workspace, fresh.id)
      assert kept.content == "a,b\n"
      assert Map.get(kept, :pruned_at) == nil
    end

    test "a workspace without retention keeps every file, however old", ctx do
      {:ok, old} = Files.store(ctx.runner, ctx.job.id, "a.png", @png)
      age_file(old, 4000)

      assert Files.prune(DateTime.utc_now()) == 0
      assert Files.get_for_download(ctx.workspace, old.id).content == @png
    end

    test "each workspace by its own retention", ctx do
      policy(ctx, %{job_files_retention_days: 30})
      {:ok, mine} = Files.store(ctx.runner, ctx.job.id, "a.png", @png)
      age_file(mine, 20)

      other = workspace_fixture()
      {:ok, _} = Workspaces.update_workspace(other, %{job_files_retention_days: 7})
      other_user = member_fixture(other)
      {other_runner, _token} = runner_fixture(other, other_user)
      other_job = job_fixture(other_runner, other_user)
      {:ok, theirs} = Files.store(other_runner, other_job.id, "a.png", @png)
      age_file(theirs, 20)

      assert Files.prune(DateTime.utc_now()) == 1
      assert Files.get_for_download(ctx.workspace, mine.id).content == @png
      assert Files.get_for_download(other, theirs.id).content == nil
    end

    test "at most :batch files per run", ctx do
      policy(ctx, %{job_files_retention_days: 1})

      for n <- 1..3 do
        {:ok, file} = Files.store(ctx.runner, ctx.job.id, "f-#{n}.txt", "x")
        age_file(file, 2)
      end

      assert Files.prune(DateTime.utc_now(), batch: 2) == 2
      assert Files.prune(DateTime.utc_now(), batch: 2) == 1
    end

    test "sending a pruned path again brings its content back", ctx do
      policy(ctx, %{job_files_retention_days: 1})
      {:ok, file} = Files.store(ctx.runner, ctx.job.id, "a.csv", "velho")
      age_file(file, 2)
      Files.prune(DateTime.utc_now())

      {:ok, _} = Files.store(ctx.runner, ctx.job.id, "a.csv", "novo")
      again = Files.get_for_download(ctx.workspace, file.id)
      assert again.content == "novo"
      assert Map.get(again, :pruned_at) == nil
    end

    test "pruned?/1 tells an emptied file apart" do
      refute JobFile.pruned?(struct(JobFile, []))
      assert JobFile.pruned?(struct(JobFile, pruned_at: DateTime.utc_now()))
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
