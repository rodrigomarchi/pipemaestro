defmodule PipeMaestro.Secrets do
  @moduledoc """
  A workspace's secrets: values the agents need (an MCP server's token, a
  test account) that should not live in a pipeline or on the runners.

  Each is an environment variable, encrypted at rest (AES-256-GCM with a key
  from the application's configuration). They are handed to the runner with
  every job, in memory only (`PipeMaestroProtocol.Job` `env`), so a
  pipeline's MCP configuration can refer to them as `${NAME}`. Their values
  are never shown back.
  """

  import Ecto.Query

  alias PipeMaestro.Repo
  alias PipeMaestro.Secrets.Secret
  alias PipeMaestro.Workspaces.Workspace
  alias PipeMaestroProtocol.Job

  @aad "pipe_maestro.secret"

  @doc "The workspace's secrets (their names), by name."
  @spec list(Workspace.t()) :: [Secret.t()]
  def list(%Workspace{id: workspace_id}) do
    Repo.all(from s in Secret, where: s.workspace_id == ^workspace_id, order_by: s.name)
  end

  @doc "Sets a secret, replacing the value of one with the same name."
  @spec put(Workspace.t(), String.t(), String.t()) ::
          {:ok, Secret.t()} | {:error, Ecto.Changeset.t()}
  def put(%Workspace{id: workspace_id}, name, value) do
    changeset =
      {%Secret{workspace_id: workspace_id}, %{name: :string, value: :string}}
      |> Ecto.Changeset.cast(%{name: name, value: value}, [:name, :value])
      |> Ecto.Changeset.validate_required([:value], message: "informe o valor")
      |> Ecto.Changeset.validate_length(:value, max: 8_192)
      |> Ecto.Changeset.validate_change(:name, fn :name, name ->
        if Job.env_name?(name),
          do: [],
          else: [name: "use LETRAS_MAIUSCULAS, números e _, e não um nome que o runner usa"]
      end)

    if changeset.valid? do
      secret = %Secret{
        workspace_id: workspace_id,
        name: name,
        encrypted_value: encrypt(value)
      }

      Repo.insert(secret,
        on_conflict: [set: [encrypted_value: secret.encrypted_value, updated_at: now()]],
        conflict_target: [:workspace_id, :name],
        returning: true
      )
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  @doc "Removes a secret. Removing one that is not there is fine."
  @spec delete(Workspace.t(), String.t()) :: :ok
  def delete(%Workspace{id: workspace_id}, name) do
    Repo.delete_all(from s in Secret, where: s.workspace_id == ^workspace_id and s.name == ^name)
    :ok
  end

  @doc "The workspace's secrets as environment variables, decrypted."
  @spec env(Workspace.t() | Ecto.UUID.t()) :: %{String.t() => String.t()}
  def env(%Workspace{id: workspace_id}), do: env(workspace_id)

  def env(workspace_id) when is_binary(workspace_id) do
    Repo.all(from s in Secret, where: s.workspace_id == ^workspace_id)
    |> Map.new(&{&1.name, decrypt(&1.encrypted_value)})
  end

  defp encrypt(value) do
    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, value, @aad, true)
    iv <> tag <> ciphertext
  end

  defp decrypt(<<iv::binary-12, tag::binary-16, ciphertext::binary>>),
    do: :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, @aad, tag, false)

  defp key do
    secret = Application.fetch_env!(:pipe_maestro, __MODULE__)[:key]
    :crypto.hash(:sha256, secret)
  end

  defp now, do: DateTime.utc_now(:second)
end
