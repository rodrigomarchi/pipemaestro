defmodule PipeMaestroRunner.Test.FilesServer do
  @moduledoc """
  A local stand-in for the control plane's file endpoint
  (`PUT /api/runner/jobs/:job_id/files?path=...`) on 127.0.0.1. Each request is
  recorded with its job, path, `authorization` and `content-type` headers and
  body (`requests/1`); it answers 201, or the status set with `respond/2`
  (404 for a control plane without the endpoint, 500 for one in trouble).
  """

  @behaviour Plug

  import Plug.Conn

  @doc "Starts serving; returns `%{url: base_url, state: agent, server: pid}`."
  def start do
    {:ok, state} = Agent.start_link(fn -> %{requests: [], status: 201} end)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__, state: state},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{url: "http://127.0.0.1:#{port}", state: state, server: server}
  end

  @doc "Every request so far, oldest first."
  def requests(%{state: state}), do: Agent.get(state, &Enum.reverse(&1.requests))

  @doc "Answers every request from now on with `status`."
  def respond(%{state: state}, status), do: Agent.update(state, &%{&1 | status: status})

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    state = opts[:state]
    {:ok, body, conn} = read_body(conn, length: 20_000_000)
    conn = fetch_query_params(conn)

    job_id =
      case conn.path_info do
        ["api", "runner", "jobs", job_id, "files"] -> job_id
        _other -> nil
      end

    request = %{
      method: conn.method,
      job_id: job_id,
      path: conn.query_params["path"],
      authorization: conn |> get_req_header("authorization") |> List.first(),
      content_type: conn |> get_req_header("content-type") |> List.first(),
      body: body
    }

    status =
      Agent.get_and_update(state, &{&1.status, %{&1 | requests: [request | &1.requests]}})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(response(status, request)))
  end

  defp response(201, request),
    do: %{path: request.path, byte_size: byte_size(request.body)}

  defp response(404, _request), do: %{error: "not_found"}
  defp response(_status, _request), do: %{error: "erro"}
end
