defmodule PipeMaestroProtocol.JobFiles do
  @moduledoc """
  The files a job leaves for the control plane: screenshots, reports, CSVs.

  A runner with the `"files"` capability (`capability/0`) gives each job a
  folder of its own, outside any worktree, and names it in the agent's
  environment (`env/0`). When the agent ends, the runner sends each regular
  file of that folder over HTTP, one request per file, out of the channel:

      PUT <path/1>?path=<relative path>
      Authorization: Bearer <runner token>
      Content-Type: application/octet-stream

  The control plane answers `201` with `%{"path", "byte_size", "sha256",
  "content_type"}`, `401` for a bad token, `404` for a job that is not the
  runner's, `413` past a limit and `422` for a path `valid_path?/1` refuses.
  Sending the same path again replaces the file. The files a runner could not
  send are counted in `"files_failed"` of `"job:finished"`.
  """

  @max_file_bytes 10_485_760
  @max_job_bytes 52_428_800
  @max_files 100
  @max_path_bytes 255

  @doc "The `Hello` capability of a runner that sends a job's files."
  @spec capability() :: String.t()
  def capability, do: "files"

  @doc "The environment variable that names the job's folder for the agent."
  @spec env() :: String.t()
  def env, do: "CP_FILES_DIR"

  @doc "The HTTP path that receives a file of the job `job_id`."
  @spec path(String.t()) :: String.t()
  def path(job_id), do: "/api/runner/jobs/#{job_id}/files"

  @doc "The largest file accepted, in bytes."
  @spec max_file_bytes() :: pos_integer()
  def max_file_bytes, do: @max_file_bytes

  @doc "The most bytes a job's files may add up to."
  @spec max_job_bytes() :: pos_integer()
  def max_job_bytes, do: @max_job_bytes

  @doc "The most files a job may keep."
  @spec max_files() :: pos_integer()
  def max_files, do: @max_files

  @doc """
  Whether `path` is a file path relative to the job's folder: segments
  separated by `/`, none empty, `.` or `..`, no `\\` or NUL, at most 255
  bytes.
  """
  @spec valid_path?(term()) :: boolean()
  def valid_path?(path) when is_binary(path) and byte_size(path) in 1..@max_path_bytes do
    String.valid?(path) and not String.contains?(path, ["\\", <<0>>]) and
      path |> String.split("/") |> Enum.all?(&(&1 not in ["", ".", ".."]))
  end

  def valid_path?(_path), do: false
end
