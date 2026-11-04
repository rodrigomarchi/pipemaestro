defmodule PipeMaestroRunner.DeviceLogin do
  @moduledoc """
  Signs the runner in with the device flow: asks the platform for a code,
  hands the URL and the code to the caller to show, and polls until a person
  approves (or denies) it in the browser, or it expires.
  """

  alias PipeMaestroProtocol.Hello

  @type code :: %{
          user_code: String.t(),
          verification_uri: String.t(),
          verification_uri_complete: String.t(),
          expires_in: pos_integer()
        }

  @type result :: %{
          token: String.t(),
          runner_id: String.t(),
          runner_name: String.t(),
          workspace_name: String.t(),
          workspace_slug: String.t()
        }

  @type error ::
          :denied
          | :expired
          | {:outdated, map()}
          | {:unexpected, term()}
          | {:unreachable, Exception.t()}

  @doc """
  Runs the whole sign-in against `url`.

  Options:
    * `:name` - the runner name to propose (default: the hostname)
    * `:on_code` - called with `t:code/0` once the code exists, to show it
    * `:req_options` - extra `Req` options (tests use `plug:`)
    * `:sleep` - how to wait between polls (tests pass a no-op)
  """
  @spec run(String.t(), Hello.t(), keyword()) :: {:ok, result()} | {:error, error()}
  def run(url, %Hello{} = hello, opts \\ []) do
    req =
      Req.new(
        [base_url: url, retry: false, receive_timeout: 15_000] ++ (opts[:req_options] || [])
      )

    with {:ok, body} <- request_code(req, hello, opts[:name]) do
      code = %{
        user_code: body["user_code"],
        verification_uri: body["verification_uri"],
        verification_uri_complete: body["verification_uri_complete"],
        expires_in: body["expires_in"]
      }

      (opts[:on_code] || fn _code -> :ok end).(code)

      deadline = System.monotonic_time(:second) + body["expires_in"]
      sleep = opts[:sleep] || (&Process.sleep/1)
      poll(req, body["device_code"], body["interval"], deadline, sleep)
    end
  end

  defp request_code(req, hello, name) do
    body = %{hello: Hello.to_map(hello), name: name}

    case Req.post(req, url: PipeMaestroProtocol.device_code_path(), json: body) do
      {:ok, %Req.Response{status: 200, body: %{"device_code" => _} = body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 409, body: %{"error" => "outdated"} = body}} ->
        {:error, {:outdated, body}}

      {:ok, %Req.Response{} = response} ->
        {:error, {:unexpected, response.body}}

      {:error, exception} ->
        {:error, {:unreachable, exception}}
    end
  end

  defp poll(req, device_code, interval, deadline, sleep) do
    if System.monotonic_time(:second) >= deadline do
      {:error, :expired}
    else
      sleep.(interval * 1_000)

      case request_token(req, device_code) do
        {:ok, result} -> {:ok, result}
        {:retry, extra} -> poll(req, device_code, interval + extra, deadline, sleep)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp request_token(req, device_code) do
    case Req.post(req,
           url: PipeMaestroProtocol.device_token_path(),
           json: %{device_code: device_code}
         ) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, result(body)}
      {:ok, %Req.Response{status: 400, body: %{"error" => code}}} -> classify(code)
      {:ok, %Req.Response{} = response} -> {:error, {:unexpected, response.body}}
      {:error, exception} -> {:error, {:unreachable, exception}}
    end
  end

  # What a token-endpoint error means for the loop: wait again (with this much
  # extra delay), or stop.
  defp classify(code) do
    case PipeMaestroProtocol.parse_device_error(code) do
      :authorization_pending -> {:retry, 0}
      :slow_down -> {:retry, 5}
      :access_denied -> {:error, :denied}
      :expired_token -> {:error, :expired}
      other -> {:error, {:unexpected, other}}
    end
  end

  defp result(body) do
    %{
      token: body["runner_token"],
      runner_id: body["runner"]["id"],
      runner_name: body["runner"]["name"],
      workspace_name: body["workspace"]["name"],
      workspace_slug: body["workspace"]["slug"]
    }
  end
end
