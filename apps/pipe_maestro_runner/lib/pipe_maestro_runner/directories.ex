defmodule PipeMaestroRunner.Directories do
  @moduledoc """
  The code directories a runner offers: every directory at the first level of
  its root (say `~/src`), each marked as a git repository or not. A task picks
  one of them by name.
  """

  alias PipeMaestroProtocol.Hello

  @doc """
  The directories under `root`, sorted by name, in the wire form of
  `PipeMaestroProtocol.Hello`. Hidden directories (`.name`) and names
  the protocol cannot carry are skipped; no root (or a missing one) offers none.
  """
  @spec scan(Path.t() | nil) :: [Hello.directory()]
  def scan(nil), do: []

  def scan(root) do
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.filter(&(Hello.valid_directory_name?(&1) and File.dir?(Path.join(root, &1))))
        |> Enum.sort()
        |> Enum.take(500)
        |> Enum.map(&%{"name" => &1, "git" => File.exists?(Path.join([root, &1, ".git"]))})

      {:error, _reason} ->
        []
    end
  end
end
