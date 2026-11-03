defmodule Mix.Tasks.ControlPlane.CreateOperator do
  @shortdoc "Creates a backoffice operator"
  @moduledoc """
  Creates a backoffice operator, asking for the password on the terminal:

      mix control_plane.create_operator ops@example.com "Ops Team"

  In a release, use `ClaudeControlPlane.Release.create_operator/3` instead.
  """
  use Mix.Task

  alias ClaudeControlPlane.Auth.Credentials
  alias ClaudeControlPlane.Backoffice

  @requirements ["app.start"]

  @impl Mix.Task
  def run([email, name]) do
    prompt = "Senha (mínimo #{Credentials.min_password_length()} caracteres):"
    password = prompt |> Mix.shell().prompt() |> String.trim()

    case Backoffice.create_operator(%{email: email, name: name, password: password}) do
      {:ok, operator} ->
        Mix.shell().info("Operador #{operator.email} criado.")

      {:error, changeset} ->
        Mix.raise("Não foi possível criar o operador: #{format_errors(changeset)}")
    end
  end

  def run(_args) do
    Mix.raise(~s(Uso: mix control_plane.create_operator EMAIL "NOME"))
  end

  defp format_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end
end
