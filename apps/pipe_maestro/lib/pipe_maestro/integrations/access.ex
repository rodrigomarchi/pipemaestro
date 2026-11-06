defmodule PipeMaestro.Integrations.Access do
  @moduledoc """
  Who may make the platform act on a git host, in the form
  `PipeMaestro.Integrations.Ingest` and `PipeMaestro.Integrations.Conversation`
  end a delivery with: a signed-in client of the connection, and whether a
  login has write access to a repository.
  """

  alias PipeMaestro.Integrations
  alias PipeMaestro.Integrations.{Client, Connection, Credentials, LinkedRepo}

  @doc "A signed-in client of the connection, or why the delivery fails."
  @spec client(Connection.t()) :: {:ok, Client.t()} | {:failed, String.t()}
  def client(connection) do
    case Credentials.client(connection) do
      {:ok, client} -> {:ok, client}
      {:error, message} -> {:failed, "sem acesso ao host: " <> message}
    end
  end

  @doc "`:ok` when `login` has write access to the repository; otherwise why not."
  @spec writer(Client.t(), LinkedRepo.t(), String.t() | nil) ::
          :ok | {:ignored, String.t()} | {:failed, String.t()}
  def writer(_client, _repo, nil), do: {:ignored, "não se sabe quem fez a mudança"}

  def writer(client, repo, login) do
    case client.provider.permission(client, repo.full_name, login) do
      {:ok, permission} when permission in [:admin, :write] ->
        :ok

      {:ok, _none} ->
        {:ignored, "o autor não tem permissão de escrita"}

      {:error, error} ->
        {:failed, "não foi possível ver a permissão do autor: " <> Integrations.describe(error)}
    end
  end
end
