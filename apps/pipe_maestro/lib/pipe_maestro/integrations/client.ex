defmodule PipeMaestro.Integrations.Client do
  @moduledoc """
  A signed-in client of a git host's API: the provider's module and a
  `Req.Request` with the base URL and the credential. It is built by
  `PipeMaestro.Integrations.Credentials.client/1`; the tests answer through
  `config :pipe_maestro, PipeMaestro.Integrations, req_options:`.
  """

  @type t :: %__MODULE__{provider: module(), req: Req.Request.t(), base_url: String.t()}

  @enforce_keys [:provider, :req, :base_url]
  defstruct [:provider, :req, :base_url]

  @doc """
  A client of `provider` at `api_url` (the API's root) sending
  `authorization`; `base_url` is the instance's own address.
  """
  @spec new(module(), String.t(), String.t(), String.t() | nil, [{String.t(), String.t()}]) ::
          t()
  def new(provider, base_url, api_url, authorization, headers \\ []) do
    req =
      Req.new(
        [
          base_url: api_url,
          headers: [{"accept", "application/json"} | auth(authorization) ++ headers],
          retry: false,
          redirect: false,
          receive_timeout: 15_000
        ] ++ req_options()
      )

    %__MODULE__{provider: provider, req: req, base_url: base_url}
  end

  @doc "Extra `Req` options from the configuration (the tests' stub)."
  @spec req_options() :: keyword()
  def req_options,
    do: Application.get_env(:pipe_maestro, PipeMaestro.Integrations, [])[:req_options] || []

  @doc """
  Sends a request and answers the body of a 2xx response, or the error as
  `PipeMaestro.Integrations.Provider` describes it.
  """
  @spec request(t(), keyword()) ::
          {:ok, term(), Req.Response.t()}
          | {:error, %{status: pos_integer() | nil, message: String.t()}}
  def request(%__MODULE__{req: req}, options) do
    case Req.request(req, options) do
      {:ok, %Req.Response{status: status, body: body} = response} when status in 200..299 ->
        {:ok, body, response}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, message: message(body)}}

      {:error, exception} ->
        {:error, %{status: nil, message: Exception.message(exception)}}
    end
  end

  defp auth(nil), do: []
  defp auth(authorization), do: [{"authorization", authorization}]

  defp message(%{"message" => message}) when is_binary(message), do: message
  defp message(%{"error_description" => message}) when is_binary(message), do: message
  defp message(%{"error" => message}) when is_binary(message), do: message
  defp message(body) when is_binary(body) and body != "", do: String.slice(body, 0, 200)
  defp message(_body), do: "sem detalhes"
end
