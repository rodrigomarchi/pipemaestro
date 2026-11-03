defmodule ClaudeControlPlaneRunner.Config do
  @moduledoc """
  The runner's credentials on disk: which platform it signed in to, its id and
  token, its workspace, the labels and capacity it was signed in with (so
  every later connection announces the same), and the root of the code
  directories it offers (`root`, set by `runner.start --root`). Stored as JSON
  readable only by its owner, in `~/.config/claude-control-plane/runner.json`
  (or `$RUNNER_CONFIG_DIR`).
  """

  @file_name "runner.json"
  @fields ~w(url runner_id runner_name token workspace_name workspace_slug)a
  @optional_fields ~w(labels capacity root)a

  @type t :: %{
          url: String.t(),
          runner_id: String.t(),
          runner_name: String.t(),
          token: String.t(),
          workspace_name: String.t(),
          workspace_slug: String.t(),
          labels: [String.t()],
          capacity: pos_integer() | nil,
          root: Path.t() | nil
        }

  @doc "The directory credentials live in."
  @spec dir() :: Path.t()
  def dir do
    System.get_env("RUNNER_CONFIG_DIR") ||
      Path.join([System.user_home!(), ".config", "claude-control-plane"])
  end

  @doc """
  The runner's single working directory, next to its credentials. Every job
  runs in it, so what one job clones, installs or builds is there for the next.
  """
  @spec workdir(Path.t()) :: Path.t()
  def workdir(dir \\ dir()), do: Path.join(dir, "workdir")

  @doc "The credentials file inside `dir`."
  @spec path(Path.t()) :: Path.t()
  def path(dir \\ dir()), do: Path.join(dir, @file_name)

  @doc "Reads the credentials."
  @spec load(Path.t()) :: {:ok, t()} | {:error, :not_found | :invalid}
  def load(dir \\ dir()) do
    with {:ok, body} <- read(path(dir)),
         {:ok, %{} = map} <- Jason.decode(body),
         config = Map.new(@fields, &{&1, map[Atom.to_string(&1)]}),
         true <- Enum.all?(Map.values(config), &is_binary/1),
         {:ok, labels} <- labels(map["labels"]),
         {:ok, capacity} <- capacity(map["capacity"]),
         {:ok, root} <- root(map["root"]) do
      {:ok, Map.merge(config, %{labels: labels, capacity: capacity, root: root})}
    else
      {:error, :not_found} -> {:error, :not_found}
      _invalid -> {:error, :invalid}
    end
  end

  @doc "Writes the credentials, readable only by the current user."
  @spec save(t(), Path.t()) :: :ok
  def save(config, dir \\ dir()) do
    File.mkdir_p!(dir)
    target = path(dir)
    temp = target <> ".tmp"

    File.write!(temp, Jason.encode_to_iodata!(Map.take(config, @fields ++ @optional_fields)))
    File.chmod!(temp, 0o600)
    File.rename!(temp, target)
  end

  @doc "Removes the credentials. Removing nothing is fine."
  @spec delete(Path.t()) :: :ok
  def delete(dir \\ dir()) do
    case File.rm(path(dir)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
    end
  end

  defp labels(nil), do: {:ok, []}

  defp labels(list) when is_list(list),
    do: if(Enum.all?(list, &is_binary/1), do: {:ok, list}, else: :invalid)

  defp labels(_other), do: :invalid

  defp root(nil), do: {:ok, nil}
  defp root(root) when is_binary(root), do: {:ok, root}
  defp root(_other), do: :invalid

  defp capacity(nil), do: {:ok, nil}
  defp capacity(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp capacity(_other), do: :invalid

  defp read(file) do
    case File.read(file) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:error, :not_found}
      {:error, _reason} -> {:error, :invalid}
    end
  end
end
