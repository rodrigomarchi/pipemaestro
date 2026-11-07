defmodule PipeMaestroProtocol.JobFilesTest do
  use ExUnit.Case, async: true

  alias PipeMaestroProtocol.JobFiles

  test "the capability, the env and the endpoint both sides agree on" do
    assert JobFiles.capability() == "files"
    assert JobFiles.env() == "CP_FILES_DIR"
    assert JobFiles.path("job-1") == "/api/runner/jobs/job-1/files"
  end

  test "the limits: per file, per job and how many files" do
    assert JobFiles.max_file_bytes() == 10_485_760
    assert JobFiles.max_job_bytes() == 52_428_800
    assert JobFiles.max_files() == 100
    assert JobFiles.max_file_bytes() < JobFiles.max_job_bytes()
  end

  describe "valid_path?/1" do
    test "accepts a relative path, in a subfolder too" do
      assert JobFiles.valid_path?("a.png")
      assert JobFiles.valid_path?("dados/r.csv")
      assert JobFiles.valid_path?("e2e/shots/claro/tarefa-1.png")
      assert JobFiles.valid_path?(".oculto")
    end

    test "refuses what would escape the job's folder or be ambiguous" do
      for bad <- [
            "",
            "../x",
            "a/../../x",
            "/etc/passwd",
            "./a.png",
            "a/./b",
            "a//b",
            "a/",
            "..",
            ".",
            "a\\b",
            "a\0b",
            String.duplicate("a", 256)
          ] do
        refute JobFiles.valid_path?(bad), "aceitou #{inspect(bad)}"
      end
    end

    test "accepts up to 255 bytes" do
      assert JobFiles.valid_path?(String.duplicate("a", 255))
    end

    test "refuses what is not a string" do
      refute JobFiles.valid_path?(nil)
      refute JobFiles.valid_path?(:a)
    end
  end
end
