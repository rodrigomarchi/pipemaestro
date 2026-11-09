defmodule PipeMaestroWeb.IntegrationWebhookController do
  @moduledoc """
  The webhooks of the integrations. A Forgejo connection has its own
  (`POST /api/integrations/<connection>/webhook`); the GitHub App has one for
  every installation (`POST /api/integrations/github/webhook`). The
  delivery is checked against the connection's secret, recorded and answered
  at once; processing happens in the background, since hosts give up on a
  slow answer and never retry. Both go to the task source of the issues of a
  git host (`PipeMaestro.TaskSources`, `PipeMaestro.Integrations.IssueSource`).
  """
  use PipeMaestroWeb, :controller

  alias PipeMaestro.Integrations.IssueSource
  alias PipeMaestro.TaskSources

  @doc "Takes one delivery of the platform's GitHub App, for whichever installation it is."
  @spec receive_app_event(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def receive_app_event(conn, _params) do
    headers = Map.new(conn.req_headers)

    case TaskSources.receive_webhook(
           IssueSource.key(),
           nil,
           headers,
           conn.assigns[:raw_body] || ""
         ) do
      {:ok, %{id: id}} ->
        conn |> put_status(202) |> json(%{delivery_id: id})

      {:ok, _ignored} ->
        json(conn, %{ok: true})

      :duplicate ->
        json(conn, %{duplicate: true})

      {:error, :bad_signature} ->
        conn |> put_status(401) |> json(%{error: "assinatura inválida"})

      {:error, :bad_payload} ->
        conn |> put_status(400) |> json(%{error: "corpo inválido"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "GitHub App não configurado"})
    end
  end

  @doc "Takes one delivery."
  @spec receive_event(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def receive_event(conn, %{"connection_id" => connection_id}) do
    headers = Map.new(conn.req_headers)

    case TaskSources.receive_webhook(
           IssueSource.key(),
           connection_id,
           headers,
           conn.assigns[:raw_body] || ""
         ) do
      {:ok, delivery} ->
        conn |> put_status(202) |> json(%{delivery_id: delivery.id})

      :duplicate ->
        json(conn, %{duplicate: true})

      {:error, :bad_signature} ->
        conn |> put_status(401) |> json(%{error: "assinatura inválida"})

      {:error, :bad_payload} ->
        conn |> put_status(400) |> json(%{error: "corpo inválido"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "integração não encontrada"})
    end
  end
end
