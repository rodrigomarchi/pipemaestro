defmodule PipeMaestroRunner.Test.DownloadServer do
  @moduledoc """
  A local platform serving the runner's binaries the way the deploy publishes
  them: `GET /downloads/runner/<file>` from a directory, on 127.0.0.1.

  Per file, a behavior set with `behave/3`: `:serve` (default), `:missing`
  (404) or `:cut` (sends half, then drops the connection). Every request is
  counted (`requests/1`).
  """

  @behaviour Plug

  import Plug.Conn

  @doc "Starts serving `dir`; returns `%{url: base_url, state: agent}`."
  def start(dir) do
    {:ok, state} = Agent.start_link(fn -> %{behaviors: %{}, requests: []} end)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__, dir: dir, state: state},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{url: "http://127.0.0.1:#{port}", state: state, server: server}
  end

  @doc "Publishes `content` as `name`, and the SHA256SUMS with every file in `dir`."
  def publish(dir, name, content, checksums \\ nil) do
    File.write!(Path.join(dir, name), content)

    sums =
      checksums ||
        for file <- File.ls!(dir), file != "SHA256SUMS", into: "" do
          hash = :crypto.hash(:sha256, File.read!(Path.join(dir, file)))
          Base.encode16(hash, case: :lower) <> "  " <> file <> "\n"
        end

    File.write!(Path.join(dir, "SHA256SUMS"), sums)
  end

  def behave(%{state: state}, file, behavior),
    do: Agent.update(state, &put_in(&1, [:behaviors, file], behavior))

  def requests(%{state: state}), do: Agent.get(state, &Enum.reverse(&1.requests))

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{path_info: ["downloads", "runner", file]} = conn, opts) do
    state = opts[:state]
    Agent.update(state, &Map.update!(&1, :requests, fn r -> [file | r] end))
    path = Path.join(opts[:dir], file)

    case {Agent.get(state, fn s -> s.behaviors[file] end), File.read(path)} do
      {:missing, _} ->
        send_resp(conn, 404, "")

      {_behavior, {:error, _}} ->
        send_resp(conn, 404, "")

      {:cut, {:ok, content}} ->
        half = binary_part(content, 0, div(byte_size(content), 2))
        conn = send_chunked(conn, 200)
        {:ok, _conn} = chunk(conn, half)
        Process.exit(self(), :kill)

      {_serve, {:ok, content}} ->
        send_resp(conn, 200, content)
    end
  end

  def call(conn, _opts), do: send_resp(conn, 404, "")
end
