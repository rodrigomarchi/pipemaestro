defmodule PipeMaestroRunner.Host do
  @moduledoc """
  What this machine announces about itself: hostname, OS, architecture,
  labels (OS, architecture and toolchains found on the PATH, plus any given on
  the command line) and capacity.
  """

  alias PipeMaestroProtocol.Hello

  @detected_tools ~w(docker podman git elixir node python3 go cargo)

  @doc """
  The hello for this machine.

  Options: `:labels` (extra labels), `:capacity` (default: the number of
  schedulers, roughly the CPU count), `:agent` (the agent CLI's version and
  sign-in, `PipeMaestroRunner.Claude.agent/1`), `:directories` (the code directories
  offered, `PipeMaestroRunner.Directories`).
  """
  @spec hello(keyword()) :: {:ok, Hello.t()} | {:error, String.t()}
  def hello(opts \\ []) do
    os = os()
    arch = arch()

    hello =
      Hello.new(%{
        protocol_version: PipeMaestroProtocol.version(),
        runner_version: runner_version(),
        hostname: hostname(),
        os: os,
        arch: arch,
        labels: [os, arch | detected_tools()] ++ Keyword.get(opts, :labels, []),
        capacity: Keyword.get(opts, :capacity) || System.schedulers_online(),
        directories: Keyword.get(opts, :directories, []),
        agent: Keyword.get(opts, :agent)
      })

    # Matching the struct makes this module depend on Hello at compile time:
    # when Hello changes, this module is recompiled with it, instead of keeping
    # a type inferred from the old struct.
    case hello do
      {:ok, %Hello{} = hello} -> {:ok, hello}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "This build's version (`PipeMaestroRunner.Version`)."
  @spec runner_version() :: String.t()
  defdelegate runner_version, to: PipeMaestroRunner.Version, as: :version

  @doc "The machine's hostname."
  @spec hostname() :: String.t()
  def hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end

  @doc "`linux`, `macos`, `windows` or the raw OS name."
  @spec os() :: String.t()
  def os do
    case :os.type() do
      {:unix, :darwin} -> "macos"
      {:unix, :linux} -> "linux"
      {:win32, _} -> "windows"
      {_family, name} -> Atom.to_string(name)
    end
  end

  @doc "The CPU architecture, e.g. `x86_64` or `aarch64`."
  @spec arch() :: String.t()
  def arch do
    :erlang.system_info(:system_architecture)
    |> to_string()
    |> String.split("-")
    |> hd()
  end

  defp detected_tools, do: Enum.filter(@detected_tools, &System.find_executable/1)
end
