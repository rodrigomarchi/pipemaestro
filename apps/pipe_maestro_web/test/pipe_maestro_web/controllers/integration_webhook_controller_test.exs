defmodule PipeMaestroWeb.IntegrationWebhookControllerTest do
  use PipeMaestroWeb.ConnCase, async: true

  alias PipeMaestro.{FakeForgejo, Integrations, Repo}
  alias PipeMaestro.Integrations.{Connection, Delivery}

  setup do
    FakeForgejo.start()
    workspace = workspace_fixture()
    %{workspace: workspace, connection: connection_fixture(workspace)}
  end

  # Signed as Forgejo signs: the HMAC of the raw body, in plain hex.
  defp post_delivery(conn, connection, body, id, secret \\ nil) do
    secret = secret || Connection.webhook_secret(connection)
    signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-forgejo-event", "issues")
    |> put_req_header("x-forgejo-event-type", "issues")
    |> put_req_header("x-forgejo-delivery", id)
    |> put_req_header("x-forgejo-signature", signature)
    |> post(~p"/api/integrations/#{connection.id}/webhook", body)
  end

  test "takes a delivery at once and processes it in the background", ctx do
    Integrations.subscribe_deliveries(ctx.workspace)
    # Spaces matter: the signature is over the body as sent.
    body = ~s({ "action": "opened",  "repository": {"full_name": "acme/nada"} })

    conn = post_delivery(ctx.conn, ctx.connection, body, "d-1")
    assert %{"delivery_id" => id} = json_response(conn, 202)
    assert_receive {:delivery_updated, %Delivery{id: ^id, status: "ignored"}}, 2_000

    conn = post_delivery(build_conn(), ctx.connection, body, "d-1")
    assert json_response(conn, 200) == %{"duplicate" => true}
  end

  test "refuses a bad signature, a bad body and an unknown connection", ctx do
    assert json_response(post_delivery(ctx.conn, ctx.connection, ~s({}), "d-2", "outro"), 401)

    assert_error_sent 400, fn ->
      post_delivery(build_conn(), ctx.connection, "não é json", "d-3")
    end

    other = Map.put(ctx.connection, :id, Ecto.UUID.generate())

    assert json_response(
             post_delivery(
               build_conn(),
               other,
               ~s({}),
               "d-4",
               Connection.webhook_secret(ctx.connection)
             ),
             404
           )

    assert Repo.all(Delivery) == []
  end
end
