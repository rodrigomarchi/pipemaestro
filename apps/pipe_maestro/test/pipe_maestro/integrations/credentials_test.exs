defmodule PipeMaestro.Integrations.CredentialsTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.FakeForgejo
  alias PipeMaestro.Integrations.{Connection, Credentials, Forgejo}
  alias PipeMaestro.Repo

  setup do
    %{fake: FakeForgejo.start(), workspace: workspace_fixture()}
  end

  defp oauth_connection(workspace, credentials) do
    connection =
      connection_fixture(workspace, %{
        "auth_kind" => "oauth",
        "oauth_client_id" => "cid",
        "oauth_client_secret" => "csecret"
      })

    if credentials,
      do: connection |> Connection.credentials_changeset(credentials) |> Repo.update!(),
      else: connection
  end

  test "a token connection sends the bot's token", %{workspace: workspace} do
    connection = connection_fixture(workspace)

    assert {:ok, client} = Credentials.client(connection)
    assert Forgejo.whoami(client) == {:ok, %{login: "pipemaestro-bot", id: 7}}
  end

  test "a valid OAuth token is used as it is", %{workspace: workspace, fake: fake} do
    Agent.update(fake, &put_in(&1, [:tokens, "access-0"], %{"login" => "ana", "id" => 8}))
    expires = DateTime.utc_now() |> DateTime.add(3000) |> DateTime.to_iso8601()

    connection =
      oauth_connection(workspace, %{
        "access_token" => "access-0",
        "refresh_token" => "r0",
        "expires_at" => expires
      })

    assert {:ok, client} = Credentials.client(connection)
    assert Forgejo.whoami(client) == {:ok, %{login: "ana", id: 8}}
    refute {"POST", "/login/oauth/access_token"} in FakeForgejo.calls(fake)
  end

  test "an expired OAuth token is refreshed and both new tokens are kept", %{
    workspace: workspace,
    fake: fake
  } do
    Agent.update(fake, &put_in(&1, [:oauth, :refresh, "r0"], :valid))
    past = DateTime.utc_now() |> DateTime.add(-10) |> DateTime.to_iso8601()

    connection =
      oauth_connection(workspace, %{
        "access_token" => "velho",
        "refresh_token" => "r0",
        "expires_at" => past
      })

    assert {:ok, client} = Credentials.client(connection)
    assert Forgejo.whoami(client) == {:ok, %{login: "ana", id: 8}}

    stored = Connection.credentials(Repo.reload!(connection))
    assert stored["access_token"] == "access-1"
    assert stored["refresh_token"] == "refresh-1"
    {:ok, expires_at, _} = DateTime.from_iso8601(stored["expires_at"])
    assert DateTime.diff(expires_at, DateTime.utc_now()) in 3500..3600

    assert {:ok, _client} = Credentials.client(Repo.reload!(connection))

    assert Enum.count(FakeForgejo.calls(fake), &(&1 == {"POST", "/login/oauth/access_token"})) ==
             1
  end

  test "two refreshes at once spend the refresh token once", %{workspace: workspace, fake: fake} do
    Agent.update(fake, &put_in(&1, [:oauth, :refresh, "r0"], :valid))
    past = DateTime.utc_now() |> DateTime.add(-10) |> DateTime.to_iso8601()

    connection =
      oauth_connection(workspace, %{
        "access_token" => "velho",
        "refresh_token" => "r0",
        "expires_at" => past
      })

    results =
      [
        Task.async(fn -> Credentials.access_token(connection) end),
        Task.async(fn -> Credentials.access_token(connection) end)
      ]
      |> Task.await_many()

    assert results == [{:ok, "access-1"}, {:ok, "access-1"}]

    assert Enum.count(FakeForgejo.calls(fake), &(&1 == {"POST", "/login/oauth/access_token"})) ==
             1
  end

  test "a refused refresh leaves the connection in error", %{workspace: workspace} do
    past = DateTime.utc_now() |> DateTime.add(-10) |> DateTime.to_iso8601()

    connection =
      oauth_connection(workspace, %{
        "access_token" => "velho",
        "refresh_token" => "usado",
        "expires_at" => past
      })

    assert {:error, message} = Credentials.client(connection)
    assert message =~ "invalid_grant"
    assert %Connection{status: "error", last_error: last_error} = Repo.reload!(connection)
    assert last_error =~ "reconecte"
  end

  test "an OAuth connection not signed in yet has no client", %{workspace: workspace} do
    assert {:error, "conecte pela página da integração"} =
             Credentials.client(oauth_connection(workspace, nil))
  end

  test "the authorization URL asks with PKCE for the API's scopes", %{workspace: workspace} do
    connection = oauth_connection(workspace, nil)
    verifier = Credentials.new_verifier()

    url =
      Credentials.authorize_url(
        connection,
        "https://pm.test/integrations/oauth/callback",
        "estado",
        verifier
      )

    %URI{path: "/login/oauth/authorize", query: query} = URI.parse(url)
    params = URI.decode_query(query)

    assert params["client_id"] == "cid"
    assert params["response_type"] == "code"
    assert params["state"] == "estado"
    assert params["redirect_uri"] == "https://pm.test/integrations/oauth/callback"
    assert params["code_challenge_method"] == "S256"

    assert params["code_challenge"] ==
             Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

    assert params["scope"] == "write:issue write:repository read:user"
    assert byte_size(verifier) >= 43
  end

  test "exchanging the code keeps the tokens", %{workspace: workspace} do
    connection = oauth_connection(workspace, nil)

    assert {:ok, %Connection{} = connection} =
             Credentials.exchange_code(
               connection,
               "code-1",
               Credentials.new_verifier(),
               "https://pm.test/cb"
             )

    assert %{"access_token" => "access-1", "refresh_token" => "refresh-1"} =
             Connection.credentials(connection)

    assert {:error, message} =
             Credentials.exchange_code(connection, "outro", "v", "https://pm.test/cb")

    assert message =~ "invalid_grant"
  end
end
