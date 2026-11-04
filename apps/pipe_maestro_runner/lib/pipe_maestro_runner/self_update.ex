defmodule PipeMaestroRunner.SelfUpdate do
  @moduledoc """
  Replaces the runner's single binary with the platform's version and runs it
  again (`PipeMaestroRunner.Update` decides when).

  The binary comes from the refusal's `download_url`
  (`PipeMaestroProtocol.Downloads`), only on the platform's own origin and
  over https (plain http only to this machine). It is written next to the
  current one, checked against `SHA256SUMS` and renamed over it: an
  interrupted download, a wrong checksum or a directory it cannot write to
  leave the current binary as it was.
  """

  alias PipeMaestroProtocol.Downloads

  @typedoc "Where the binary and its checksums are."
  @type urls :: %{binary: String.t(), checksums: String.t()}

  @typedoc "How the new binary runs: in this terminal, or by the service manager."
  @type mode :: :interactive | :service

  @type error ::
          :checksum_mismatch
          | {:missing_checksum, String.t()}
          | {:http_status, non_neg_integer(), String.t()}
          | {:not_writable, Path.t()}
          | {:file, Path.t(), File.posix()}
          | {:download, String.t(), Exception.t()}

  @loopback ["localhost", "127.0.0.1", "::1"]

  # What the old binary's environment carries about its unpacked release, which
  # the new binary has to unpack and point at on its own.
  @release_env ~w(__BURRITO_BIN_PATH __BURRITO ROOTDIR BINDIR EMU PROGNAME)

  @doc "This machine's target (`PipeMaestroProtocol.Downloads.targets/0`)."
  @spec target() :: {:ok, String.t()} | {:error, :unsupported_platform}
  def target, do: target(:os.type(), :erlang.system_info(:system_architecture))

  @doc "The target for an `:os.type/0` and a system architecture."
  @spec target({atom(), atom()}, charlist()) ::
          {:ok, String.t()} | {:error, :unsupported_platform}
  def target({:unix, os}, architecture) when os in [:darwin, :linux] do
    prefix = if os == :darwin, do: "macos_", else: "linux_"

    case to_string(architecture) do
      "aarch64" <> _rest -> {:ok, prefix <> "arm64"}
      "arm64" <> _rest -> {:ok, prefix <> "arm64"}
      "x86_64" <> _rest -> {:ok, prefix <> "x86_64"}
      _other -> {:error, :unsupported_platform}
    end
  end

  def target(_os, _architecture), do: {:error, :unsupported_platform}

  @doc """
  The binary's and the checksums' URLs inside `download_url` (the platform's
  `/downloads/runner/` when nil), as long as it is on `platform_url`'s origin:
  the same scheme, host and port, with https, or http to this machine.
  """
  @spec urls(String.t(), String.t() | nil, String.t()) ::
          {:ok, urls()} | {:error, :foreign_origin}
  def urls(platform_url, download_url, target) do
    platform = URI.parse(platform_url)
    download = URI.merge(platform, download_url || "/downloads/runner/")

    if same_origin?(platform, download) and secure?(download) do
      base = download |> URI.to_string() |> String.trim_trailing("/")

      {:ok,
       %{
         binary: base <> "/" <> Downloads.binary_name(target),
         checksums: base <> "/" <> Downloads.checksums_name()
       }}
    else
      {:error, :foreign_origin}
    end
  end

  defp same_origin?(a, b),
    do: {a.scheme, downcase(a.host), a.port} == {b.scheme, downcase(b.host), b.port}

  defp secure?(%URI{scheme: "https", host: host}) when is_binary(host), do: true
  defp secure?(%URI{scheme: "http", host: host}), do: downcase(host) in @loopback
  defp secure?(_uri), do: false

  defp downcase(nil), do: nil
  defp downcase(host), do: String.downcase(host)

  @doc """
  Downloads the binary to a temporary file next to `bin`, checks it against
  `SHA256SUMS` and renames it over `bin`, executable.

  Options: `:urls` (`urls/3`), `:target` and `:progress` (called with the
  percentage downloaded, and with 100 at the end).
  """
  @spec install(Path.t(), keyword()) :: :ok | {:error, error()}
  def install(bin, opts) do
    dir = Path.dirname(bin)
    tmp = temporary(bin)

    case File.open(tmp, [:write, :exclusive, :binary, :raw]) do
      {:ok, file} ->
        try do
          download_into(file, tmp, bin, opts)
        after
          File.close(file)
          remove(tmp)
        end

      {:error, reason} when reason in [:eacces, :erofs, :eperm] ->
        {:error, {:not_writable, dir}}

      {:error, reason} ->
        {:error, {:file, tmp, reason}}
    end
  end

  defp download_into(file, tmp, bin, opts) do
    name = Downloads.binary_name(opts[:target])
    progress = opts[:progress] || fn _percent -> :ok end

    with {:ok, sums} <- fetch_checksums(opts[:urls].checksums),
         {:ok, expected} <- checksum_for(sums, name),
         {:ok, actual} <- stream(opts[:urls].binary, file, progress),
         :ok <- match(expected, actual),
         :ok <- sync(file, tmp),
         :ok <- file_op(File.chmod(tmp, 0o755), tmp),
         :ok <- file_op(File.rename(tmp, bin), bin) do
      progress.(100)
      :ok
    end
  end

  defp fetch_checksums(url) do
    case Req.get(url, request_options()) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, Downloads.parse_checksums(body)}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status, url}}
      {:error, exception} -> {:error, {:download, url, exception}}
    end
  end

  defp checksum_for(sums, name) do
    case Map.fetch(sums, name) do
      {:ok, hash} -> {:ok, hash}
      :error -> {:error, {:missing_checksum, name}}
    end
  end

  # Writes the body to `file` as it arrives, hashing it on the way.
  defp stream(url, file, progress) do
    into = fn {:data, data}, {req, resp} ->
      {:cont, {req, received(resp, data, file, progress)}}
    end

    case Req.get(url, request_options() ++ [into: into]) do
      {:ok, %Req.Response{status: 200} = resp} ->
        case resp.private[:self_update] do
          %{error: nil, hash: hash} ->
            {:ok, Base.encode16(:crypto.hash_final(hash), case: :lower)}

          %{error: reason} ->
            {:error, {:file, url, reason}}

          nil ->
            {:ok, Base.encode16(:crypto.hash(:sha256, ""), case: :lower)}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status, url}}

      {:error, exception} ->
        {:error, {:download, url, exception}}
    end
  end

  defp received(%Req.Response{status: 200} = resp, data, file, progress) do
    state =
      resp.private[:self_update] ||
        %{hash: :crypto.hash_init(:sha256), bytes: 0, percent: -1, error: nil}

    state =
      case :file.write(file, data) do
        :ok ->
          bytes = state.bytes + byte_size(data)
          %{state | hash: :crypto.hash_update(state.hash, data), bytes: bytes}

        {:error, reason} ->
          %{state | error: reason}
      end

    Req.Response.put_private(resp, :self_update, report(state, resp, progress))
  end

  defp received(resp, _data, _file, _progress), do: resp

  defp report(state, resp, progress) do
    with [length] <- Req.Response.get_header(resp, "content-length"),
         {total, ""} when total > 0 <- Integer.parse(length),
         percent when percent > state.percent <- div(state.bytes * 100, total) do
      progress.(percent)
      %{state | percent: percent}
    else
      _unknown -> state
    end
  end

  defp match(hash, hash), do: :ok
  defp match(_expected, _actual), do: {:error, :checksum_mismatch}

  defp sync(file, tmp), do: file_op(:file.sync(file), tmp)

  defp file_op(:ok, _path), do: :ok
  defp file_op({:error, reason}, path), do: {:error, {:file, path, reason}}

  # Redirects are not followed: one could lead to another origin.
  defp request_options,
    do: [retry: false, redirect: false, decode_body: false, receive_timeout: 60_000]

  defp temporary(bin) do
    random = 6 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    Path.join(Path.dirname(bin), "." <> Path.basename(bin) <> ".update-" <> random)
  end

  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:file, path, reason}}
    end
  end

  @doc """
  Removes the temporary files an interrupted update left next to `bin`.
  """
  @spec clean_stale(Path.t()) :: :ok
  def clean_stale(bin) do
    prefix = "." <> Path.basename(bin) <> ".update-"
    dir = Path.dirname(bin)

    case File.ls(dir) do
      {:ok, files} ->
        for file <- files, String.starts_with?(file, prefix), do: remove(Path.join(dir, file))
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  @doc """
  Runs the updated `bin` with the same `argv`.

  `:interactive`: as a child that takes over this terminal (it inherits stdin,
  stdout and stderr); returns its exit status once it ends. `:service`: exits
  with 0 (option `:halt`, `System.halt/1` by default), and the service manager
  starts the new binary in its place.
  """
  @spec relaunch(Path.t(), [String.t()], mode(), keyword()) :: term()
  def relaunch(bin, argv, mode, opts \\ [])

  def relaunch(bin, argv, :interactive, _opts) do
    port =
      Port.open({:spawn_executable, bin}, [
        :nouse_stdio,
        :exit_status,
        args: argv,
        env: child_env(System.get_env())
      ])

    receive do
      {^port, {:exit_status, status}} -> status
    end
  end

  def relaunch(_bin, _argv, :service, opts) do
    halt = opts[:halt] || (&System.halt/1)
    halt.(0)
  end

  @doc """
  The variables the new binary must not inherit from `env`: the old one's
  unpacked release (`Port.open/2`'s `{name, false}`).
  """
  @spec child_env(%{String.t() => String.t()}) :: [{charlist(), false}]
  def child_env(env) do
    for {name, _value} <- env,
        name in @release_env or String.starts_with?(name, "RELEASE_"),
        do: {String.to_charlist(name), false}
  end
end
