defmodule PipeMaestro.Integrations.Credentials do
  @moduledoc """
  A connection's credential turned into a signed-in client
  (`PipeMaestro.Integrations.Client`).

  - **Token** (`auth_kind` `"token"`): a bot user's token, sent as is.
  - **OAuth2** (`"oauth"`): the authorization code flow with PKCE
    (`authorize_url/4`, `exchange_code/4`), always asking for the API's scopes
    (`@scopes`): without them Forgejo grants a token with every right. The
    access token lasts an hour; Forgejo takes each refresh token once, so a
    refresh runs in a transaction that locks the connection's row and keeps
    the new pair before anyone else may read it. A refused refresh leaves the
    connection in `"error"`: someone must sign in again.
  """

  import Ecto.Query

  alias PipeMaestro.Integrations.{Client, Connection, Forgejo, GitHub}
  alias PipeMaestro.Repo

  @scopes "write:issue write:repository read:user"
  # A token this close to expiring is refreshed before use.
  @margin_seconds 60

  @doc "A client of the connection's host, signed in."
  @spec client(Connection.t()) :: {:ok, Client.t()} | {:error, String.t()}
  def client(%Connection{provider: "forgejo", auth_kind: "token"} = connection) do
    case Connection.credentials(connection) do
      %{"token" => token} -> {:ok, Forgejo.client(connection.base_url, "token " <> token)}
      _none -> {:error, "informe o token do usuário-bot"}
    end
  end

  def client(%Connection{provider: "forgejo", auth_kind: "oauth"} = connection) do
    with {:ok, token} <- access_token(connection),
         do: {:ok, Forgejo.client(connection.base_url, "Bearer " <> token)}
  end

  def client(%Connection{provider: "github", auth_kind: "github_app"} = connection) do
    with {:ok, token} <- installation_token(connection),
         do: {:ok, GitHub.client(token)}
  end

  def client(%Connection{}), do: {:error, "provedor não suportado"}

  # The installation's token, kept with the connection and minted again
  # (under the row's lock) when it is about to expire.
  defp installation_token(%Connection{id: id}) do
    Repo.transaction(fn ->
      connection = Repo.one!(from c in Connection, where: c.id == ^id, lock: "FOR UPDATE")
      credentials = Connection.credentials(connection)

      cond do
        credentials["installation_id"] == nil ->
          {:error, "instale o GitHub App pela página da integração"}

        fresh?(credentials) ->
          {:ok, credentials["access_token"]}

        true ->
          mint(connection, credentials)
      end
    end)
    |> elem(1)
  end

  defp mint(connection, credentials) do
    case GitHub.installation_token(credentials["installation_id"]) do
      {:ok, %{"token" => token, "expires_at" => expires_at}} ->
        credentials =
          Map.merge(credentials, %{"access_token" => token, "expires_at" => expires_at})

        connection |> Connection.credentials_changeset(credentials) |> Repo.update!()
        {:ok, token}

      {:error, error} ->
        {:error, "o GitHub recusou o token da instalação: " <> describe(error)}
    end
  end

  defp describe(%{status: status, message: message}), do: "#{status} #{message}"

  @doc """
  What git signs in to the connection's host with (ADR 0035): `"host"`,
  `"username"`, `"password"` and, for a token that expires, `"expires_at"`.
  """
  @spec git_credential(Connection.t(), PipeMaestro.Integrations.LinkedRepo.t() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def git_credential(connection, repo \\ nil)

  # On GitHub, a token of an hour for the repository only, to write its code.
  def git_credential(%Connection{provider: "github"} = connection, %{external_id: repo_id})
      when is_binary(repo_id) do
    with %{"installation_id" => installation_id} <- Connection.credentials(connection),
         {:ok, %{"token" => token, "expires_at" => expires_at}} <-
           GitHub.installation_token(installation_id,
             repository_ids: [String.to_integer(repo_id)],
             permissions: %{contents: "write"}
           ) do
      {:ok,
       %{
         "host" => host(connection),
         "username" => "x-access-token",
         "password" => token,
         "expires_at" => expires_at
       }}
    else
      {:error, error} -> {:error, describe(error)}
      _not_installed -> {:error, "instale o GitHub App pela página da integração"}
    end
  end

  def git_credential(%Connection{provider: "forgejo", auth_kind: "token"} = connection, _repo) do
    case Connection.credentials(connection) do
      %{"token" => token} ->
        {:ok,
         %{
           "host" => host(connection),
           "username" => connection.bot_login || "pipemaestro",
           "password" => token
         }}

      _none ->
        {:error, "informe o token do usuário-bot"}
    end
  end

  def git_credential(%Connection{provider: "forgejo", auth_kind: "oauth"} = connection, _repo) do
    with {:ok, token} <- access_token(connection) do
      expires_at =
        connection |> Repo.reload!() |> Connection.credentials() |> Map.get("expires_at")

      {:ok,
       %{
         "host" => host(connection),
         "username" => "oauth2",
         "password" => token,
         "expires_at" => expires_at
       }}
    end
  end

  def git_credential(%Connection{}, _repo), do: {:error, "provedor não suportado"}

  defp host(connection) do
    case URI.parse(connection.base_url) do
      %URI{host: host, port: port, scheme: scheme}
      when {scheme, port} in [{"https", 443}, {"http", 80}] ->
        host

      %URI{host: host, port: port} ->
        "#{host}:#{port}"
    end
  end

  @doc """
  The OAuth connection's access token, refreshed first when it is about to
  expire.
  """
  @spec access_token(Connection.t()) :: {:ok, String.t()} | {:error, String.t()}
  def access_token(%Connection{id: id}) do
    result =
      Repo.transaction(fn ->
        connection = Repo.one!(from c in Connection, where: c.id == ^id, lock: "FOR UPDATE")
        credentials = Connection.credentials(connection)

        cond do
          credentials["refresh_token"] == nil ->
            {:error, "conecte pela página da integração"}

          fresh?(credentials) ->
            {:ok, credentials["access_token"]}

          true ->
            refresh(connection, credentials["refresh_token"])
        end
      end)

    case result do
      {:ok, {:error, {:refused, message}}} ->
        mark_error(id, "o Forgejo recusou renovar o acesso (#{message}); reconecte a integração")
        {:error, message}

      {:ok, reply} ->
        reply
    end
  end

  @doc "A random PKCE code verifier."
  @spec new_verifier() :: String.t()
  def new_verifier, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @doc "Where to send a person to authorize the connection."
  @spec authorize_url(Connection.t(), String.t(), String.t(), String.t()) :: String.t()
  def authorize_url(%Connection{} = connection, redirect_uri, state, verifier) do
    query =
      URI.encode_query(%{
        "client_id" => connection.oauth_client_id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "state" => state,
        "scope" => @scopes,
        "code_challenge" => challenge(verifier),
        "code_challenge_method" => "S256"
      })

    connection.base_url <> "/login/oauth/authorize?" <> query
  end

  @doc "Trades the authorization code for the tokens and keeps them."
  @spec exchange_code(Connection.t(), String.t(), String.t(), String.t()) ::
          {:ok, Connection.t()} | {:error, String.t()}
  def exchange_code(%Connection{} = connection, code, verifier, redirect_uri) do
    params = %{
      grant_type: "authorization_code",
      code: code,
      code_verifier: verifier,
      redirect_uri: redirect_uri
    }

    with {:ok, credentials} <- token_request(connection, params) do
      {:ok, connection |> Connection.credentials_changeset(credentials) |> Repo.update!()}
    end
  end

  defp fresh?(credentials) do
    case DateTime.from_iso8601(credentials["expires_at"] || "") do
      {:ok, expires_at, _} -> DateTime.diff(expires_at, DateTime.utc_now()) > @margin_seconds
      _invalid -> false
    end
  end

  defp refresh(connection, refresh_token) do
    case token_request(connection, %{grant_type: "refresh_token", refresh_token: refresh_token}) do
      {:ok, credentials} ->
        connection |> Connection.credentials_changeset(credentials) |> Repo.update!()
        {:ok, credentials["access_token"]}

      {:error, message} ->
        {:error, {:refused, message}}
    end
  end

  defp token_request(connection, params) do
    client = Client.new(Forgejo, connection.base_url, connection.base_url, nil)

    form =
      Map.merge(params, %{
        client_id: connection.oauth_client_id,
        client_secret: Connection.oauth_client_secret(connection)
      })

    case Client.request(client, method: :post, url: "/login/oauth/access_token", form: form) do
      {:ok, %{"access_token" => access} = body, _} ->
        expires_at =
          DateTime.utc_now() |> DateTime.add(body["expires_in"] || 3600) |> DateTime.to_iso8601()

        {:ok,
         %{
           "access_token" => access,
           "refresh_token" => body["refresh_token"],
           "expires_at" => expires_at
         }}

      {:ok, _body, _} ->
        {:error, "resposta sem token"}

      {:error, %{message: message}} ->
        {:error, message}
    end
  end

  defp mark_error(id, message) do
    Repo.update_all(from(c in Connection, where: c.id == ^id),
      set: [status: "error", last_error: message, updated_at: DateTime.utc_now(:second)]
    )
  end

  defp challenge(verifier), do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
end
