defmodule PipeMaestroProtocol.Downloads do
  @moduledoc """
  What the `download_url` of an `"outdated"` refusal points at: a directory
  with one runner binary per target, `pipemaestro_<alvo>`, and a
  `SHA256SUMS` in `sha256sum`'s format, as `scripts/build_runner_binaries.sh`
  and `scripts/deploy.sh` publish them. The platform links them on the
  runners page; the runner downloads its own to update itself.
  """

  @targets ["macos_arm64", "macos_x86_64", "linux_x86_64", "linux_arm64"]

  @doc "The targets the deploy publishes a binary for (Burrito's, in `mix.exs`)."
  @spec targets() :: [String.t()]
  def targets, do: @targets

  @doc "The binary's file name for `target`, inside `download_url`."
  @spec binary_name(String.t()) :: String.t()
  def binary_name(target), do: "pipemaestro_" <> target

  @doc "The checksums file's name, inside `download_url`."
  @spec checksums_name() :: String.t()
  def checksums_name, do: "SHA256SUMS"

  @doc """
  The checksums in a `SHA256SUMS`: file name → SHA-256 in lowercase hex.
  Takes `sha256sum`'s text (`<hash>  <nome>`) and binary (`<hash> *<nome>`)
  modes; lines out of that shape are skipped.
  """
  @spec parse_checksums(String.t()) :: %{String.t() => String.t()}
  def parse_checksums(content) do
    content
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/\A([0-9a-fA-F]{64}) [ *](\S.*?)\s*\z/, line) do
        [_line, hash, name] -> [{name, String.downcase(hash)}]
        nil -> []
      end
    end)
    |> Map.new()
  end
end
