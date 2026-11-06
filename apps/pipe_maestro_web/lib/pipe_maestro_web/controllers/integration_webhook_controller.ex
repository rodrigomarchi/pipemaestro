defmodule PipeMaestroWeb.IntegrationWebhookController do
  @moduledoc """
  A connection's webhook (`POST /api/integrations/<connection>/webhook`): the
  delivery is checked against the connection's secret, recorded and answered
  at once; processing happens in the background
  (`PipeMaestro.Integrations.Ingest`), since hosts give up on a slow answer
  and never retry.
  """
  use PipeMaestroWeb, :controller

  alias PipeMaestro.Integrations.Ingest

  @doc "Takes one delivery."
  @spec receive_event(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def receive_event(conn, %{"connection_id" => connection_id}) do
    headers = Map.new(conn.req_headers)

    case Ingest.receive_webhook(connection_id, headers, conn.assigns[:raw_body] || "") do
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
