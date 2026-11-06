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

defmodule PipeMaestroWeb.IntegrationGitHubSetupTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.{FakeGitHub, Integrations, Repo}
  alias PipeMaestro.Integrations.Connection
  alias PipeMaestroWeb.IntegrationOAuth

  setup :register_and_log_in_member

  setup %{workspace: workspace, user: user} do
    FakeGitHub.start()

    {:ok, connection} =
      Integrations.create_connection(workspace, user, %{
        "name" => "GitHub",
        "provider" => "github",
        "auth_kind" => "github_app"
      })

    %{connection: connection}
  end

  defp state_of(url),
    do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

  test "the form installs the App: saving sends the person to GitHub", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/integrations/new")
    view |> form("#integration-form", connection: %{provider: "github"}) |> render_change()
    assert has_element?(view, "[data-testid=integration-github-help]")
    refute has_element?(view, "[data-testid=integration-base-url]")

    assert {:error, {:redirect, %{to: url}}} =
             view
             |> form("#integration-form",
               connection: %{provider: "github", name: "GitHub da Acme"}
             )
             |> render_submit()

    assert url =~ "https://github.test/apps/pipemaestro-test/installations/new?state="
  end

  test "setup confirms the installation of the person who installed it", ctx do
    state = state_of(IntegrationOAuth.github_install_url(ctx.connection, ctx.user))
    page = ~p"/w/#{ctx.workspace.slug}/integrations/#{ctx.connection.id}"

    conn =
      get(
        ctx.conn,
        ~p"/integrations/github/setup?#{[installation_id: "55", code: "code-1", state: state]}"
      )

    assert redirected_to(conn) == page
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "não administra essa instalação"

    conn =
      get(
        ctx.conn,
        ~p"/integrations/github/setup?#{[installation_id: "99", code: "code-1", state: state]}"
      )

    assert redirected_to(conn) == page
    assert %Connection{status: "active", external_account_id: "99"} = Repo.reload!(ctx.connection)

    conn =
      get(
        ctx.conn,
        ~p"/integrations/github/setup?#{[installation_id: "99", code: "code-1", state: "forjado"]}"
      )

    assert redirected_to(conn) == ~p"/workspaces"
  end

  test "the App's webhook is answered before a connection's own route", ctx do
    body = JSON.encode!(%{"action" => "deleted", "installation" => %{"id" => 99}})

    signature =
      "sha256=" <>
        (:crypto.mac(:hmac, :sha256, "segredo-do-app", body) |> Base.encode16(case: :lower))

    conn =
      ctx.conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-event", "installation")
      |> put_req_header("x-hub-signature-256", signature)
      |> post(~p"/api/integrations/github/webhook", body)

    assert json_response(conn, 200) == %{"ok" => true}
  end
end
