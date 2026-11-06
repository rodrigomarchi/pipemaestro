defmodule PipeMaestro.Integrations.Connection do
  @moduledoc """
  A git host connected to a workspace: a Forgejo instance or GitHub.

  - `auth_kind`: `"token"` (a bot user's token) or `"oauth"` (a person
    signs in through the instance's OAuth2) on Forgejo; `"github_app"` on
    GitHub, whose installation is `external_account_id`.
  - `api_mode`: who calls the host's API. `"control_plane"` reacts,
    comments, labels, posts statuses and keeps the pull request;
    `"runner"` leaves the pull request and the comments to the runner, for an
    instance the platform cannot reach.
  - `status`: `"pending"` until the credential is checked, `"active"`, or
    `"error"` with `last_error`.

  The credential (a map), the OAuth client secret and the webhook's secret are
  kept encrypted (`PipeMaestro.Vault`). A token typed in the form arrives in
  the virtual `token`; left blank on an edit, the stored one stays.
  """
  use PipeMaestro.Schema

  import Ecto.Changeset

  alias PipeMaestro.Integrations.{GitHub, HostGuard}
  alias PipeMaestro.Vault
  alias PipeMaestro.Workspaces.Workspace

  @aad "pipe_maestro.integration"
  @providers ~w(forgejo github)
  @auth_kinds %{"forgejo" => ~w(token oauth), "github" => ~w(github_app)}
  @api_modes ~w(control_plane runner)
  @local_hosts ~w(localhost 127.0.0.1)

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          provider: String.t() | nil,
          base_url: String.t() | nil,
          auth_kind: String.t() | nil,
          api_mode: String.t(),
          token: String.t() | nil,
          encrypted_credentials: binary() | nil,
          encrypted_webhook_secret: binary() | nil,
          oauth_client_id: String.t() | nil,
          oauth_client_secret: String.t() | nil,
          encrypted_oauth_client_secret: binary() | nil,
          bot_login: String.t() | nil,
          bot_user_id: String.t() | nil,
          server_version: String.t() | nil,
          status: String.t(),
          last_error: String.t() | nil,
          checked_at: DateTime.t() | nil,
          connected_by_id: Ecto.UUID.t() | nil,
          external_account_id: String.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          workspace: Workspace.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "integration_connections" do
    field :name, :string
    field :provider, :string
    field :base_url, :string
    field :auth_kind, :string
    field :api_mode, :string, default: "control_plane"
    field :token, :string, virtual: true, redact: true
    field :encrypted_credentials, :binary, redact: true
    field :encrypted_webhook_secret, :binary, redact: true
    field :oauth_client_id, :string
    field :oauth_client_secret, :string, virtual: true, redact: true
    field :encrypted_oauth_client_secret, :binary, redact: true
    field :bot_login, :string
    field :bot_user_id, :string
    field :server_version, :string
    field :status, :string, default: "pending"
    field :last_error, :string
    field :checked_at, :utc_datetime
    field :connected_by_id, :binary_id
    field :external_account_id, :string

    belongs_to :workspace, Workspace

    timestamps()
  end

  @doc "The providers a connection may be to."
  @spec providers() :: [String.t()]
  def providers, do: @providers

  @doc "Who may call the host's API."
  @spec api_modes() :: [String.t()]
  def api_modes, do: @api_modes

  @doc """
  Changeset for what a person types: name, provider, URL, authentication,
  API mode and, by kind, the token or the OAuth client.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :name,
      :provider,
      :base_url,
      :auth_kind,
      :api_mode,
      :token,
      :oauth_client_id,
      :oauth_client_secret
    ])
    |> put_github_url()
    |> update_change(:name, &String.trim/1)
    |> update_change(:base_url, &(&1 |> String.trim() |> String.trim_trailing("/")))
    |> validate_required([:name], message: "dê um nome à conexão")
    |> validate_length(:name, max: 80)
    |> validate_required([:provider, :auth_kind])
    |> validate_inclusion(:provider, @providers, message: "escolha Forgejo ou GitHub")
    |> validate_inclusion(:api_mode, @api_modes)
    |> validate_required([:base_url], message: "informe o endereço")
    |> validate_change(:base_url, &validate_base_url/2)
    |> validate_auth_kind()
    |> validate_credential()
    |> put_secrets()
    |> unique_constraint(:name,
      name: :integration_connections_workspace_id_name_index,
      message: "já existe uma conexão com esse nome"
    )
  end

  @doc "The GitHub App's installation a person confirmed, now the connection's credential."
  @spec installation_changeset(t(), String.t()) :: Ecto.Changeset.t()
  def installation_changeset(connection, installation_id) do
    connection
    |> credentials_changeset(%{"installation_id" => installation_id})
    |> change(external_account_id: installation_id)
    |> unique_constraint(:external_account_id,
      name: :integration_connections_provider_external_account_id_index
    )
  end

  @doc "Records the checked identity and version of the host, or the error."
  @spec check_changeset(t(), {:ok, map()} | {:error, String.t()}, DateTime.t()) ::
          Ecto.Changeset.t()
  def check_changeset(connection, {:ok, info}, now) do
    change(connection,
      bot_login: info.login,
      bot_user_id: to_string(info.id),
      server_version: info[:version],
      status: "active",
      last_error: nil,
      checked_at: now
    )
  end

  def check_changeset(connection, {:error, message}, now),
    do: change(connection, status: "error", last_error: message, checked_at: now)

  @doc "Stores a new credential map (OAuth tokens, a GitHub installation)."
  @spec credentials_changeset(t(), map()) :: Ecto.Changeset.t()
  def credentials_changeset(connection, credentials),
    do: change(connection, encrypted_credentials: Vault.encrypt_term(credentials, @aad))

  @doc "A new random secret for the webhook."
  @spec webhook_secret_changeset(t()) :: Ecto.Changeset.t()
  def webhook_secret_changeset(connection),
    do: change(connection, encrypted_webhook_secret: Vault.encrypt(new_secret(), @aad))

  @doc "The decrypted credential, `%{}` when there is none."
  @spec credentials(t()) :: map()
  def credentials(%__MODULE__{encrypted_credentials: nil}), do: %{}

  def credentials(%__MODULE__{encrypted_credentials: blob}) do
    {:ok, credentials} = Vault.decrypt_term(blob, @aad)
    credentials
  end

  @doc "The webhook's secret."
  @spec webhook_secret(t()) :: String.t()
  def webhook_secret(%__MODULE__{encrypted_webhook_secret: blob}) do
    {:ok, secret} = Vault.decrypt(blob, @aad)
    secret
  end

  @doc "The OAuth client's secret, `nil` without one."
  @spec oauth_client_secret(t()) :: String.t() | nil
  def oauth_client_secret(%__MODULE__{encrypted_oauth_client_secret: nil}), do: nil

  def oauth_client_secret(%__MODULE__{encrypted_oauth_client_secret: blob}) do
    {:ok, secret} = Vault.decrypt(blob, @aad)
    secret
  end

  # A GitHub connection is to the App's GitHub.
  defp put_github_url(changeset) do
    if get_field(changeset, :provider) == "github",
      do: put_change(changeset, :base_url, GitHub.web_url()),
      else: changeset
  end

  defp validate_base_url(:base_url, url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> []
      %URI{scheme: "http", host: host} when host in @local_hosts -> local_http()
      _other -> [base_url: "use o endereço https da instância"]
    end
  end

  # Plain http only to a local host, and only where private hosts are allowed
  # (development, tests, a self-hosted platform).
  defp local_http do
    if HostGuard.private_allowed?(), do: [], else: [base_url: "use o endereço https da instância"]
  end

  defp validate_auth_kind(changeset) do
    allowed = Map.get(@auth_kinds, get_field(changeset, :provider), [])
    validate_inclusion(changeset, :auth_kind, allowed, message: "não vale para esse provedor")
  end

  defp validate_credential(changeset) do
    case get_field(changeset, :auth_kind) do
      "token" ->
        require_secret(
          changeset,
          :token,
          :encrypted_credentials,
          "informe o token do usuário-bot"
        )

      "oauth" ->
        changeset
        |> validate_required([:oauth_client_id], message: "informe o Client ID")
        |> require_secret(
          :oauth_client_secret,
          :encrypted_oauth_client_secret,
          "informe o Client Secret"
        )

      _other ->
        changeset
    end
  end

  # A secret typed now, or one already stored.
  defp require_secret(changeset, field, stored, message) do
    if get_change(changeset, field) || Map.get(changeset.data, stored),
      do: changeset,
      else: add_error(changeset, field, message)
  end

  defp put_secrets(changeset) do
    changeset
    |> put_encrypted(:token, :encrypted_credentials, &Vault.encrypt_term(%{"token" => &1}, @aad))
    |> put_encrypted(
      :oauth_client_secret,
      :encrypted_oauth_client_secret,
      &Vault.encrypt(&1, @aad)
    )
    |> then(fn changeset ->
      if get_field(changeset, :encrypted_webhook_secret),
        do: changeset,
        else: put_change(changeset, :encrypted_webhook_secret, Vault.encrypt(new_secret(), @aad))
    end)
  end

  defp put_encrypted(changeset, field, stored, encrypt) do
    case get_change(changeset, field) do
      nil -> changeset
      value -> put_change(changeset, stored, encrypt.(value))
    end
  end

  defp new_secret, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
