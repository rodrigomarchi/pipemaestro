defmodule PipeMaestro.Integrations.ProviderSupport do
  @moduledoc """
  What the providers (`PipeMaestro.Integrations.Forgejo`,
  `PipeMaestro.Integrations.GitHub`) share to read a host's answers: a request
  whose body does not matter, steps that stop at the first error, and the
  host's timestamps and names.
  """

  alias PipeMaestro.Integrations.Client

  @doc "Sends a request whose answer's body does not matter."
  @spec request_ok(Client.t(), keyword()) :: :ok | {:error, map()}
  def request_ok(client, options) do
    with {:ok, _body, _response} <- Client.request(client, options), do: :ok
  end

  @doc "Runs `fun` on each item until one fails, answering that failure."
  @spec each_ok(Enumerable.t(), (term() -> :ok | term())) :: :ok | term()
  def each_ok(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc "A host's ISO 8601 timestamp, to the second; `nil` when missing or invalid."
  @spec datetime(String.t() | nil) :: DateTime.t() | nil
  def datetime(nil), do: nil

  def datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _invalid -> nil
    end
  end

  @doc """
  The commit statuses of a host's combined status (`GET
  /commits/:sha/status`) as checks: the latest of each context, which the
  combined status already is.
  """
  @spec status_checks(map()) :: [map()]
  def status_checks(combined) do
    for status <- combined["statuses"] || [] do
      %{
        name: status["context"],
        state: status_state(status["state"] || status["status"]),
        url: status["target_url"],
        summary: status["description"]
      }
    end
  end

  defp status_state(state) when state in ["success"], do: :success
  defp status_state(state) when state in ["failure", "error"], do: :failure
  defp status_state(_pending_or_warning), do: :pending

  @doc "A repository's name in lower case (hosts ignore case in it)."
  @spec downcase(String.t() | nil) :: String.t() | nil
  def downcase(nil), do: nil
  def downcase(text), do: String.downcase(text)
end
