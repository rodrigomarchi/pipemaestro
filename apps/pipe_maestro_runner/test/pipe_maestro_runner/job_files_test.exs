defmodule PipeMaestroRunner.JobFilesTest do
  use ExUnit.Case, async: true

  alias PipeMaestroRunner.JobFiles
  alias PipeMaestroRunner.Test.FilesServer

  @moduletag :tmp_dir

  defp write!(dir, path, content) do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  defp paths({files, _skipped}), do: Enum.map(files, & &1.path)

  test "each job's folder sits under the workdir, outside any worktree", %{tmp_dir: dir} do
    assert JobFiles.dir(dir, "j1") == Path.join([dir, "files", "j1"])

    JobFiles.prepare(dir, "j1")
    assert File.dir?(JobFiles.dir(dir, "j1"))

    write!(JobFiles.dir(dir, "j1"), "a.txt", "x")
    assert :ok = JobFiles.clear(dir)
    refute File.exists?(Path.join(dir, "files"))
  end

  describe "collect/2" do
    test "the regular files, by path, in subfolders too; not symlinks", %{tmp_dir: dir} do
      write!(dir, "b.png", "png")
      write!(dir, "dados/r.csv", "a,b\n")
      File.ln_s!(Path.join(dir, "b.png"), Path.join(dir, "atalho.png"))
      File.mkdir_p!(Path.join(dir, "vazia"))

      assert {files, 0} = JobFiles.collect(dir, %{})
      assert Enum.map(files, & &1.path) == ["b.png", "dados/r.csv"]
    end

    test "a symlinked folder is not followed", %{tmp_dir: dir} do
      outside = Path.join(dir, "fora")
      write!(outside, "segredo.txt", "x")
      files_dir = Path.join(dir, "files")
      File.mkdir_p!(files_dir)
      File.ln_s!(outside, Path.join(files_dir, "link"))

      assert paths(JobFiles.collect(files_dir, %{})) == []
    end

    test "a file above the limit is skipped and counted", %{tmp_dir: dir} do
      write!(
        dir,
        "grande.bin",
        :binary.copy("a", PipeMaestroProtocol.JobFiles.max_file_bytes() + 1)
      )

      write!(dir, "pequeno.txt", "x")

      assert {files, 1} = JobFiles.collect(dir, %{})
      assert Enum.map(files, & &1.path) == ["pequeno.txt"]
    end

    test "past the number of files a job may send, the rest is skipped and counted",
         %{tmp_dir: dir} do
      max = PipeMaestroProtocol.JobFiles.max_files()

      for n <- 1..(max + 2),
          do: write!(dir, "f-#{String.pad_leading("#{n}", 3, "0")}.txt", "x")

      assert {files, 2} = JobFiles.collect(dir, %{})
      assert length(files) == max
    end

    test "a file whose name carries a secret's value is skipped and counted", %{tmp_dir: dir} do
      write!(dir, "token-s3cr3t-valor.txt", "x")
      write!(dir, "ok.txt", "x")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {files, 1} = JobFiles.collect(dir, %{"GRAFANA_TOKEN" => "s3cr3t-valor"})
          assert Enum.map(files, & &1.path) == ["ok.txt"]
        end)

      assert log =~ "segredo"
      refute log =~ "s3cr3t-valor"
    end

    test "a folder that does not exist has nothing", %{tmp_dir: dir} do
      assert JobFiles.collect(Path.join(dir, "nao-existe"), %{}) == {[], 0}
    end
  end

  describe "upload/5" do
    setup do
      server = FilesServer.start()
      %{server: server}
    end

    test "sends each file with the runner's token and counts them", %{tmp_dir: dir} = ctx do
      write!(dir, "a.png", "png")
      write!(dir, "dados/r.csv", "a,b\n")
      {files, 0} = JobFiles.collect(dir, %{})

      assert JobFiles.upload(files, ctx.server.url, "cpr_teste", "j1", []) ==
               %{uploaded: 2, failed: 0}

      assert [a, r] = FilesServer.requests(ctx.server)
      assert {a.method, a.job_id, a.path, a.body} == {"PUT", "j1", "a.png", "png"}
      assert {r.path, r.body} == {"dados/r.csv", "a,b\n"}
      assert a.authorization == "Bearer cpr_teste"
      assert a.content_type =~ "application/octet-stream"
    end

    test "a 4xx is not tried again", %{tmp_dir: dir} = ctx do
      write!(dir, "a.png", "png")
      {files, 0} = JobFiles.collect(dir, %{})
      FilesServer.respond(ctx.server, 413)

      assert JobFiles.upload(files, ctx.server.url, "cpr_teste", "j1", []) ==
               %{uploaded: 0, failed: 1}

      assert length(FilesServer.requests(ctx.server)) == 1
    end

    test "a 5xx is tried again before giving up", %{tmp_dir: dir} = ctx do
      write!(dir, "a.png", "png")
      {files, 0} = JobFiles.collect(dir, %{})
      FilesServer.respond(ctx.server, 503)

      assert JobFiles.upload(files, ctx.server.url, "cpr_teste", "j1",
               retry_delay: fn _attempt -> 0 end
             ) == %{uploaded: 0, failed: 1}

      assert length(FilesServer.requests(ctx.server)) > 1
    end

    test "a control plane out of reach counts every file as failed", %{tmp_dir: dir} = ctx do
      write!(dir, "a.png", "png")
      {files, 0} = JobFiles.collect(dir, %{})
      :ok = Supervisor.stop(ctx.server.server)

      assert JobFiles.upload(files, ctx.server.url, "cpr_teste", "j1",
               retry_delay: fn _attempt -> 0 end
             ) == %{uploaded: 0, failed: 1}
    end
  end
end
