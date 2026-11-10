defmodule PipeMaestroWeb.RunnerFileController do
  @moduledoc """
  Where a runner sends the files a job left in `CP_FILES_DIR`, one request per
  file (`PipeMaestroProtocol.JobFiles`): `PUT
  /api/runner/jobs/:job_id/files?path=<relative path>`, with the runner's
  token as `Bearer` and the raw file as an `application/octet-stream` body.

  A file past the workspace's quota is refused with a 413 whose body says
  `quota_exceeded` (the runner does not repeat a 4xx); the job counts it.

  Neither the body nor the path is ever logged.
  """
  use PipeMaestroWeb, :controller

  alias PipeMaestro.Jobs.Files
  alias PipeMaestro.Runners
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.Workspaces
  alias PipeMaestroProtocol.JobFiles

  # How much of the body one read takes.
  @read_length 1_048_576

  @doc "Keeps the file at `path` of the runner's job."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"job_id" => job_id} = params) do
    case authenticate(conn) do
      {:ok, runner} -> store(conn, runner, job_id, Map.get(params, "path", ""))
      {:error, reason} -> error(conn, reason)
    end
  end

  defp store(conn, runner, job_id, path) do
    with :ok <- octet_stream(conn),
         {:ok, content, conn} <- read_file(conn),
         {:ok, file} <- Files.store(runner, job_id, path, content) do
      conn
      |> put_status(201)
      |> json(%{
        path: file.path,
        byte_size: file.byte_size,
        sha256: file.sha256,
        content_type: file.content_type
      })
    else
      {:error, :quota_exceeded} ->
        workspace = Workspaces.get_workspace!(runner.workspace_id)
        reply(conn, 413, %{error: "quota_exceeded", quota_bytes: Files.quota_bytes(workspace)})

      {:error, reason} ->
        error(conn, reason)

      {:error, reason, conn} ->
        error(conn, reason)
    end
  end

  defp authenticate(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         %Runner{} = runner <- Runners.authenticate_runner(String.trim(token)) do
      {:ok, runner}
    else
      _missing -> {:error, :unauthorized}
    end
  end

  defp octet_stream(conn) do
    case get_req_header(conn, "content-type") do
      ["application/octet-stream" <> _params] -> :ok
      _other -> {:error, :unsupported_media_type}
    end
  end

  # Refuses early by the declared length, then reads until the limit.
  defp read_file(conn) do
    limit = JobFiles.max_file_bytes()

    case get_req_header(conn, "content-length") do
      [length] ->
        case Integer.parse(length) do
          {size, ""} when size > limit -> {:error, :too_large, conn}
          _fits -> read_chunks(conn, [], 0, limit)
        end

      _none ->
        read_chunks(conn, [], 0, limit)
    end
  end

  defp read_chunks(conn, acc, size, limit) do
    case Plug.Conn.read_body(conn, length: @read_length, read_length: @read_length) do
      {status, chunk, conn} when size + byte_size(chunk) > limit and status in [:ok, :more] ->
        {:error, :too_large, conn}

      {:ok, chunk, conn} ->
        {:ok, IO.iodata_to_binary([acc, chunk]), conn}

      {:more, chunk, conn} ->
        read_chunks(conn, [acc, chunk], size + byte_size(chunk), limit)

      {:error, _reason} ->
        {:error, :bad_request, conn}
    end
  end

  defp error(conn, :unauthorized), do: reply(conn, 401, %{error: "unauthorized"})
  defp error(conn, :unsupported_media_type), do: reply(conn, 415, %{error: "unsupported"})
  defp error(conn, :not_found), do: reply(conn, 404, %{error: "not_found"})
  defp error(conn, :invalid_path), do: reply(conn, 422, %{error: "invalid_path"})
  defp error(conn, :bad_request), do: reply(conn, 400, %{error: "bad_request"})

  defp error(conn, :too_large),
    do: reply(conn, 413, %{error: "too_large", limit: JobFiles.max_file_bytes()})

  defp reply(conn, status, body), do: conn |> put_status(status) |> json(body)
end
