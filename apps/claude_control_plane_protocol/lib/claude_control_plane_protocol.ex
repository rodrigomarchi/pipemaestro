defmodule ClaudeControlPlaneProtocol do
  @moduledoc """
  The contract between a runner and the control plane.

  Both sides depend on this app and on nothing of each other's. The contract is
  public and versioned: a runner announces the version it speaks, and the
  control plane keeps serving older versions for a defined compatibility window.
  The written spec is `docs/specs/protocolo-runner.md`.
  """

  @version 1

  @device_errors ~w(authorization_pending slow_down expired_token access_denied invalid_request)

  @typedoc "An error a runner can get while polling for its token."
  @type device_error ::
          :authorization_pending
          | :slow_down
          | :expired_token
          | :access_denied
          | :invalid_request

  @doc "The protocol version this build speaks."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Protocol versions the control plane accepts from a runner."
  @spec supported_versions() :: [pos_integer()]
  def supported_versions, do: [@version]

  @doc "Path of the WebSocket the runner connects to (`<path>/websocket`)."
  @spec socket_path() :: String.t()
  def socket_path, do: "/runner/socket"

  @doc "The channel topic of one runner."
  @spec runner_topic(String.t()) :: String.t()
  def runner_topic(runner_id) when is_binary(runner_id), do: "runner:" <> runner_id

  @doc "Where a runner asks for a device code."
  @spec device_code_path() :: String.t()
  def device_code_path, do: "/api/runner/device/code"

  @doc "Where a runner polls for its token."
  @spec device_token_path() :: String.t()
  def device_token_path, do: "/api/runner/device/token"

  @doc "Every error code the token endpoint may answer with, as sent on the wire."
  @spec device_errors() :: [String.t()]
  def device_errors, do: @device_errors

  @doc "Parses an error code from the wire. Unknown codes are `:invalid_request`."
  @spec parse_device_error(String.t()) :: device_error()
  def parse_device_error("authorization_pending"), do: :authorization_pending
  def parse_device_error("slow_down"), do: :slow_down
  def parse_device_error("expired_token"), do: :expired_token
  def parse_device_error("access_denied"), do: :access_denied
  def parse_device_error(_code), do: :invalid_request
end
