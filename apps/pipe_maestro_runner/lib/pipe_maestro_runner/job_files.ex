defmodule PipeMaestroRunner.JobFiles do
  @moduledoc """
  The folder each job gets for the files people should see on the platform
  (screenshots, reports, CSVs): `<workdir>/files/<job_id>`, outside any
  worktree, named to the agent in `CP_FILES_DIR`
  (`PipeMaestroProtocol.JobFiles`).

  Once the agent ends, `collect/2` lists the folder's regular files within the
  protocol's limits, and `upload/5` sends each one to the control plane over
  HTTP. Symlinks are never followed; a file whose path carries the value of
  one of the job's secrets is never sent, so the value never leaves the
  machine.
  """

  alias PipeMaestroProtocol.JobFiles

  require Logger

  # Secrets shorter than this would match too many names (as in
  # `PipeMaestroRunner.LogCollector`).
  @min_secret_bytes 6
  @receive_timeout 30_000

  @typedoc "A file to send: its path in the job's folder, where it is and its size."
  @type file :: %{path: String.t(), full: Path.t(), size: non_neg_integer()}

  @doc "The folder of the job `job_id`."
  @spec dir(Path.t(), String.t()) :: Path.t()
  def dir(workdir, job_id), do: Path.join([workdir, "files", job_id])

  @doc "Creates the job's folder and returns it."
  @spec prepare(Path.t(), String.t()) :: Path.t()
  def prepare(workdir, job_id) do
    dir = dir(workdir, job_id)
    File.mkdir_p!(dir)
    dir
  end

  @doc "Removes every job's folder: what a runner that stopped left behind."
  @spec clear(Path.t()) :: :ok
  def clear(workdir) do
    _removed = File.rm_rf(Path.join(workdir, "files"))
    :ok
  end

  @doc """
  The regular files under `dir` to send, by path, and how many were skipped:
  past the size or number limits, with a path the protocol refuses, or with
  the value of one of `env`'s secrets in the path. Symlinks are ignored.
  """
  @spec collect(Path.t(), %{optional(String.t()) => String.t()} | nil) ::
          {[file()], non_neg_integer()}
  def collect(dir, env) do
    secrets = for {_name, value} <- env || %{}, byte_size(value) >= @min_secret_bytes, do: value

    {files, skipped, _total} =
      dir
      |> walk("")
      |> Enum.sort_by(& &1.path)
      |> Enum.reduce({[], 0, 0}, fn file, {kept, skipped, total} ->
        case refusal(file, secrets, length(kept), total) do
          nil ->
            {[file | kept], skipped, total + file.size}

          :secret ->
            # The path itself carries the secret: it is not written anywhere.
            Logger.warning("Um arquivo do job não sobe: o nome traz um segredo.",
              runner_event: "job_file_skipped"
            )

            {kept, skipped + 1, total}

          reason ->
            Logger.warning("O arquivo #{file.path} do job não sobe: #{reason}.",
              runner_event: "job_file_skipped"
            )

            {kept, skipped + 1, total}
        end
      end)

    {Enum.reverse(files), skipped}
  end

  defp walk(dir, prefix) do
    case File.ls(dir) do
      {:ok, names} -> Enum.flat_map(names, &entry(dir, prefix, &1))
      {:error, _reason} -> []
    end
  end

  defp entry(dir, prefix, name) do
    full = Path.join(dir, name)
    path = if prefix == "", do: name, else: prefix <> "/" <> name

    case File.lstat(full) do
      {:ok, %File.Stat{type: :regular, size: size}} -> [%{path: path, full: full, size: size}]
      {:ok, %File.Stat{type: :directory}} -> walk(full, path)
      _symlink_or_other -> []
    end
  end

  defp refusal(file, secrets, count, total) do
    cond do
      Enum.any?(secrets, &String.contains?(file.path, &1)) -> :secret
      not JobFiles.valid_path?(file.path) -> "nome inválido"
      file.size > JobFiles.max_file_bytes() -> "acima de #{JobFiles.max_file_bytes()} bytes"
      count >= JobFiles.max_files() -> "o job já tem #{JobFiles.max_files()} arquivos"
      total + file.size > JobFiles.max_job_bytes() -> "o job passaria do total permitido"
      true -> nil
    end
  end

  @doc """
  Sends each file to the control plane at `url`, as the runner `token`, and
  counts how many arrived. A network error or a 5xx is tried again, a 4xx is
  not. `req_options` go to `Req` (tests pass `retry_delay`).
  """
  @spec upload([file()], String.t(), String.t(), String.t(), keyword()) :: %{
          uploaded: non_neg_integer(),
          failed: non_neg_integer()
        }
  def upload(files, url, token, job_id, req_options) do
    options =
      Keyword.merge(
        [
          url: String.trim_trailing(url, "/") <> JobFiles.path(job_id),
          headers: [
            {"authorization", "Bearer " <> token},
            {"content-type", "application/octet-stream"}
          ],
          retry: :transient,
          max_retries: 2,
          retry_delay: &(500 * Integer.pow(2, &1)),
          retry_log_level: false,
          receive_timeout: @receive_timeout,
          decode_body: false
        ],
        req_options
      )

    Enum.reduce(files, %{uploaded: 0, failed: 0}, fn file, counts ->
      if send_file(file, options),
        do: %{counts | uploaded: counts.uploaded + 1},
        else: %{counts | failed: counts.failed + 1}
    end)
  end

  defp send_file(file, options) do
    with {:ok, body} <- File.read(file.full),
         {:ok, %Req.Response{status: status}} when status in 200..299 <-
           Req.put(Keyword.merge(options, params: [path: file.path], body: body)) do
      true
    else
      failure ->
        Logger.warning("O arquivo #{file.path} do job não subiu: #{reason(failure)}.",
          runner_event: "job_file_upload_failed"
        )

        false
    end
  end

  defp reason({:ok, %Req.Response{status: status}}), do: "a plataforma respondeu #{status}"
  defp reason({:error, %{__exception__: true} = error}), do: Exception.message(error)
  defp reason({:error, reason}), do: inspect(reason)
end
