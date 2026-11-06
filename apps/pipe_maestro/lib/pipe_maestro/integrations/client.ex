defmodule PipeMaestro.Integrations.Client do
  @moduledoc """
  A signed-in client of a git host's API: the provider's module and a
  `Req.Request` with the base URL and the credential. It is built by
  `PipeMaestro.Integrations.Credentials.client/1`; the tests answer through
  `config :pipe_maestro, PipeMaestro.Integrations, req_options:`.
  """

  @type t :: %__MODULE__{provider: module(), req: Req.Request.t(), base_url: String.t()}

  alias PipeMaestro.Integrations.HostGuard

  @max_waits 2
  @max_wait_seconds 30

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
  `PipeMaestro.Integrations.Provider` describes it (a body that is not the
  host's JSON error is not echoed). The address must pass
  `PipeMaestro.Integrations.HostGuard`. A host that says it is
  being called too much (429, or 403 with `retry-after` or no requests left,
  as GitHub's secondary limits do) is asked again after the wait it gives,
  at most `@max_waits` times and `@max_wait_seconds` each.
  """
  @spec request(t(), keyword()) ::
          {:ok, term(), Req.Response.t()}
          | {:error, %{status: pos_integer() | nil, message: String.t()}}
  def request(%__MODULE__{} = client, options), do: request(client, options, @max_waits)

  defp request(%__MODULE__{req: req} = client, options, waits_left) do
    case HostGuard.check(to_string(options[:url] || "") |> absolute(req)) do
      :ok -> send_request(client, options, waits_left)
      {:error, message} -> {:error, %{status: nil, message: message}}
    end
  end

  # The request's address: its own when absolute, under the base URL otherwise.
  defp absolute("http" <> _ = url, _req), do: url
  defp absolute(_path, req), do: to_string(req.options[:base_url])

  defp send_request(%__MODULE__{req: req} = client, options, waits_left) do
    case Req.request(req, options) do
      {:ok, %Req.Response{status: status, body: body} = response} when status in 200..299 ->
        {:ok, body, response}

      {:ok, %Req.Response{status: status, body: body} = response} ->
        case wait_for(response) do
          seconds when is_integer(seconds) and waits_left > 0 ->
            Process.sleep(seconds * 1000)
            send_request(client, options, waits_left - 1)

          _no_wait ->
            {:error, %{status: status, message: message(body)}}
        end

      {:error, exception} ->
        {:error, %{status: nil, message: Exception.message(exception)}}
    end
  end

  # How long a host that limits the calls asks to wait, or `nil`.
  defp wait_for(%Req.Response{status: status} = response) when status in [403, 429] do
    retry_after = header_integer(response, "retry-after")
    exhausted? = Req.Response.get_header(response, "x-ratelimit-remaining") == ["0"]

    cond do
      retry_after -> min(retry_after, @max_wait_seconds)
      status == 429 or exhausted? -> 1
      true -> nil
    end
  end

  defp wait_for(_response), do: nil

  defp header_integer(response, name) do
    with [value | _] <- Req.Response.get_header(response, name),
         {seconds, ""} <- Integer.parse(value),
         do: seconds,
         else: (_none -> nil)
  end

  defp auth(nil), do: []
  defp auth(authorization), do: [{"authorization", authorization}]

  defp message(%{"message" => message}) when is_binary(message), do: message
  defp message(%{"error_description" => message}) when is_binary(message), do: message
  defp message(%{"error" => message}) when is_binary(message), do: message
  defp message(_body), do: "sem detalhes"
end
