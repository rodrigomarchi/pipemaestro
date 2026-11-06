defmodule PipeMaestroWeb.IntegrationOAuthControllerTest do
  use PipeMaestroWeb.ConnCase, async: true

  alias PipeMaestro.{FakeForgejo, Repo}
  alias PipeMaestro.Integrations.Connection
  alias PipeMaestroWeb.IntegrationOAuth

  setup :register_and_log_in_member

  setup %{workspace: workspace} do
    FakeForgejo.start()

    connection =
      connection_fixture(workspace, %{
        "auth_kind" => "oauth",
        "token" => nil,
        "oauth_client_id" => "cid",
        "oauth_client_secret" => "cs"
      })

    %{connection: connection}
  end

  defp state_of(url),
    do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

  test "keeps the tokens and checks the connection", ctx do
    state = state_of(IntegrationOAuth.authorize_url(ctx.connection, ctx.user))
    conn = get(ctx.conn, ~p"/integrations/oauth/callback?#{[code: "code-1", state: state]}")

    assert redirected_to(conn) == ~p"/w/#{ctx.workspace.slug}/integrations/#{ctx.connection.id}"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "ana"
    connection = Repo.reload!(ctx.connection)
    assert connection.status == "active"
    assert %{"access_token" => "access-1"} = Connection.credentials(connection)
  end

  test "refuses a state that was tampered with or is another person's", ctx do
    conn = get(ctx.conn, ~p"/integrations/oauth/callback?#{[code: "code-1", state: "forjado"]}")
    assert redirected_to(conn) == ~p"/workspaces"

    other = member_fixture(ctx.workspace)
    state = state_of(IntegrationOAuth.authorize_url(ctx.connection, other))
    conn = get(ctx.conn, ~p"/integrations/oauth/callback?#{[code: "code-1", state: state]}")
    assert redirected_to(conn) == ~p"/workspaces"
    assert Connection.credentials(Repo.reload!(ctx.connection)) == %{}
  end

  test "a denial or a refused code goes back with the reason", ctx do
    state = state_of(IntegrationOAuth.authorize_url(ctx.connection, ctx.user))
    page = ~p"/w/#{ctx.workspace.slug}/integrations/#{ctx.connection.id}"

    conn =
      get(ctx.conn, ~p"/integrations/oauth/callback?#{[error: "access_denied", state: state]}")

    assert redirected_to(conn) == page
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "negada"

    conn = get(ctx.conn, ~p"/integrations/oauth/callback?#{[code: "outro", state: state]}")
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid_grant"
  end

  test "someone no longer an admin cannot finish", ctx do
    member = member_fixture(ctx.workspace)
    state = state_of(IntegrationOAuth.authorize_url(ctx.connection, member))

    conn =
      get(
        log_in_user(build_conn(), member),
        ~p"/integrations/oauth/callback?#{[code: "code-1", state: state]}"
      )

    assert conn.status == 403
  end
end
