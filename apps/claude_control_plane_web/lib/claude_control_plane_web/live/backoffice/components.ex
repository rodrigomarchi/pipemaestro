defmodule ClaudeControlPlaneWeb.Backoffice.Components do
  @moduledoc "Small pieces shared by the backoffice screens."
  use ClaudeControlPlaneWeb, :html

  alias ClaudeControlPlane.Auth.Credentials

  @doc "Active/disabled badge for a user or an operator."
  attr :disabled_at, :any, required: true, doc: "the record's `disabled_at`"
  attr :rest, :global

  @spec status_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def status_badge(assigns) do
    ~H"""
    <.badge
      :if={is_nil(@disabled_at)}
      size="sm"
      variant="soft"
      color="success"
      dot
      label="Ativo"
      {@rest}
    />
    <.badge :if={@disabled_at} size="sm" variant="soft" color="gray" dot label="Desativado" {@rest} />
    """
  end

  @doc "Help text for a password field, stating the minimum length."
  @spec password_hint() :: String.t()
  def password_hint do
    "Mínimo de #{Credentials.min_password_length()} caracteres. " <>
      "Envie para a pessoa por um canal seguro."
  end

  @doc "A date as `dd/mm/yyyy`."
  @spec format_date(DateTime.t()) :: String.t()
  def format_date(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%d/%m/%Y")
end
