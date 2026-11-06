defmodule PipeMaestroWeb.IntegrationOAuth do
  @moduledoc """
  The web half of a connection's OAuth2 sign-in
  (`PipeMaestro.Integrations.Credentials`): the `state` sent to the host
  carries, encrypted with the endpoint's secret and valid for ten minutes,
  the connection, the person and the PKCE verifier, so nothing waits in the
  session and the host never sees the verifier.
  """

  alias PipeMaestro.Accounts.User
  alias PipeMaestro.Integrations.{Connection, Credentials}
  alias PipeMaestroWeb.{Endpoint, IntegrationComponents}

  @salt "integration oauth"
  @max_age 600

  @doc "Where to send `user` to authorize `connection` on its host."
  @spec authorize_url(Connection.t(), User.t()) :: String.t()
  def authorize_url(%Connection{} = connection, %User{} = user) do
    verifier = Credentials.new_verifier()

    state =
      Phoenix.Token.encrypt(Endpoint, @salt, %{
        "c" => connection.id,
        "u" => user.id,
        "v" => verifier
      })

    Credentials.authorize_url(
      connection,
      IntegrationComponents.oauth_redirect_uri(),
      state,
      verifier
    )
  end

  @doc "What a `state` the host sent back carries: the connection's id, the person's and the verifier."
  @spec read_state(String.t()) ::
          {:ok, %{connection_id: String.t(), user_id: String.t(), verifier: String.t()}} | :error
  def read_state(state) when is_binary(state) do
    case Phoenix.Token.decrypt(Endpoint, @salt, state, max_age: @max_age) do
      {:ok, %{"c" => connection_id, "u" => user_id, "v" => verifier}} ->
        {:ok, %{connection_id: connection_id, user_id: user_id, verifier: verifier}}

      _invalid ->
        :error
    end
  end

  def read_state(_state), do: :error
end
