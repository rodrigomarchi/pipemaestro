defmodule PipeMaestroWeb.IntegrationComponents do
  @moduledoc """
  Pieces shared by the integration screens (`PipeMaestroWeb.IntegrationLive.*`):
  a connection's status, the provider's name, the platform's URLs a git host
  must know (the webhook and the OAuth callback) and the natural keys of test
  ids.
  """
  use Phoenix.Component
  use PipeMaestroWeb, :verified_routes

  import PetalComponents.Badge

  alias PipeMaestro.Integrations
  alias PipeMaestro.Integrations.Connection

  @doc "A connection's status as a badge."
  attr :connection, Connection, required: true
  attr :rest, :global

  @spec integration_status(map()) :: Phoenix.LiveView.Rendered.t()
  def integration_status(assigns) do
    {color, label} =
      case assigns.connection.status do
        "active" -> {"success", "ativa"}
        "error" -> {"danger", "com erro"}
        _pending -> {"warning", "pendente"}
      end

    assigns = assign(assigns, color: color, label: label)

    ~H"""
    <.badge color={@color} variant="soft" size="sm" label={@label} {@rest} />
    """
  end

  @doc "The provider's name for a person."
  @spec provider_name(String.t()) :: String.t()
  def provider_name("forgejo"), do: "Forgejo"
  def provider_name("github"), do: "GitHub"
  def provider_name(other), do: other

  @doc "How the connection signs in, for a person."
  @spec auth_name(String.t()) :: String.t()
  def auth_name("token"), do: "token do bot"
  def auth_name("oauth"), do: "OAuth"
  def auth_name("github_app"), do: "GitHub App"
  def auth_name(other), do: other

  @doc "Who calls the host's API, for a person."
  @spec api_mode_name(String.t()) :: String.t()
  def api_mode_name("runner"), do: "runner chama o host"
  def api_mode_name(_control_plane), do: "plataforma chama o host"

  @doc "The kind of a trigger, for a person."
  @spec trigger_kind_name(String.t()) :: String.t()
  def trigger_kind_name("label"), do: "Label adicionada"
  def trigger_kind_name("comment"), do: "Comando em comentário"
  def trigger_kind_name("opened"), do: "Toda issue nova"
  def trigger_kind_name(other), do: other

  @doc "The address the host sends the connection's webhook to."
  @spec webhook_url(Connection.t()) :: String.t()
  def webhook_url(%Connection{} = connection),
    do: PipeMaestroWeb.Endpoint.url() <> Integrations.webhook_path(connection)

  @doc "The OAuth callback to register on the host."
  @spec oauth_redirect_uri() :: String.t()
  def oauth_redirect_uri, do: url(~p"/integrations/oauth/callback")

  @doc "`count` and the noun, singular or plural."
  @spec plural(non_neg_integer(), String.t(), String.t()) :: String.t()
  def plural(1, singular, _plural), do: "1 #{singular}"
  def plural(count, _singular, plural), do: "#{count} #{plural}"

  @doc "A test id's natural key from a name: lower case, words joined by hyphens."
  @spec key(String.t()) :: String.t()
  def key(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end
end
