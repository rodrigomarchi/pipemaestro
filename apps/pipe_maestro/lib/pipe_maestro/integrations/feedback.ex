defmodule PipeMaestro.Integrations.Feedback do
  @moduledoc """
  What the platform shows on the git host about an issue it took
  (`docs/specs/integracoes.md`, section 5), when the connection lets the
  platform call the host (`api_mode` `"control_plane"`).

  Feedback never stops the work: a failure to reach the host is left for the
  next change or the reconciliation.
  """

  alias PipeMaestro.Integrations.{Client, Connection, Labels, LinkedRepo}

  @doc """
  Tells the issue's author the platform took it: a 👀 reaction and the state
  label (`:triaging` or the task's status).
  """
  @spec acknowledge(Connection.t(), Client.t(), LinkedRepo.t(), pos_integer(), atom()) :: :ok
  def acknowledge(%Connection{api_mode: "control_plane"}, client, repo, number, status) do
    _ = client.provider.add_reaction(client, repo.full_name, {:issue, number}, "eyes")
    _ = set_state_label(client, repo, number, status)
    :ok
  end

  def acknowledge(_connection, _client, _repo, _number, _status), do: :ok

  @doc "Puts the state label for `status` on the issue, taking the other state labels off."
  @spec set_state_label(Client.t(), LinkedRepo.t(), pos_integer(), atom()) ::
          :ok | {:error, map()}
  def set_state_label(client, repo, number, status) do
    case Labels.for_status(repo.label_prefix, status) do
      nil ->
        :ok

      label ->
        others = Labels.state_labels(repo.label_prefix) -- [label]
        client.provider.set_labels(client, repo.full_name, number, add: [label], remove: others)
    end
  end
end
