defmodule PipeMaestroWeb.JobFileController do
  @moduledoc """
  Downloads a file a job left (`PipeMaestro.Jobs.Files`) for a member of its
  workspace. Raster images open in the browser; everything else, SVG and
  HTML included, is downloaded, never rendered, and nothing is sniffed. A file
  the workspace's retention emptied answers 410.
  """
  use PipeMaestroWeb, :controller

  alias PipeMaestro.Jobs.{Files, JobFile}
  alias PipeMaestro.Workspaces
  alias PipeMaestro.Workspaces.Workspace

  @doc "Sends the file `id` of the workspace `workspace_slug`."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"workspace_slug" => slug, "id" => id}) do
    with %Workspace{} = workspace <-
           Workspaces.get_workspace_for_user(conn.assigns.current_scope.user, slug),
         %JobFile{pruned_at: nil} = file <- Files.get_for_download(workspace, id) do
      disposition = if Files.image?(file), do: "inline", else: "attachment"

      conn
      |> put_resp_content_type(file.content_type, nil)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-disposition", "#{disposition}; #{filename(file.path)}")
      |> put_resp_header("content-security-policy", "sandbox; default-src 'none'")
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_resp(200, file.content)
    else
      nil ->
        conn |> put_status(404) |> text("Not Found")

      %JobFile{} ->
        conn |> put_status(410) |> text("Este anexo foi removido pela retenção do workspace.")
    end
  end

  defp filename(path),
    do: "filename*=UTF-8''" <> URI.encode(Path.basename(path), &URI.char_unreserved?/1)
end
