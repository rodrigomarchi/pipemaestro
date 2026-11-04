defmodule PipeMaestroProtocol.Version do
  @moduledoc """
  The version scheme the runner and the control plane share.

  A release is `AAAA-MM-DD.NN`: the local date of the machine that cut it and
  the day's sequence, from `01`, padded to two digits and growing without
  padding past `99` (`2026-11-04.100`). Its source of truth is an annotated git
  tag `runner-AAAA-MM-DD.NN`; tags in any other format are ignored.

  A build at a commit with a release tag is that release. Any other build is a
  development build: `<release>+dev.<commit>` on top of the latest release
  reachable from its commit, or `dev+<commit>` when there is none
  (`dev+unknown` without git).

  The functions here are pure; `PipeMaestroProtocol.Version.Git` reads
  the tags from a repository.
  """

  @tag_prefix "runner-"
  @release ~r/^(\d{4})-(\d{2})-(\d{2})\.(\d{2,})$/
  @dev_on_release ~r/^(\d{4}-\d{2}-\d{2}\.\d{2,})\+dev\.([0-9a-z]+)$/
  @dev ~r/^dev\+([0-9a-z]+)$/

  @typedoc "A release: its date and the day's number."
  @type release :: {Date.t(), pos_integer()}

  @typedoc "What a version string is."
  @type parsed ::
          {:release, Date.t(), pos_integer()}
          | {:dev, release() | nil, String.t()}
          | :unknown

  @doc "The release of `date` with the day's `number`, e.g. `2026-11-04.01`."
  @spec format(Date.t(), pos_integer()) :: String.t()
  def format(%Date{} = date, number) when is_integer(number) and number > 0 do
    "#{Date.to_iso8601(date)}.#{number |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  @doc "Reads a release tag (`runner-AAAA-MM-DD.NN`); any other tag is `:error`."
  @spec parse_tag(String.t()) :: {:ok, release()} | :error
  def parse_tag(@tag_prefix <> version), do: parse_release(version)
  def parse_tag(_tag), do: :error

  @doc "Reads a version: a release, a development build or `:unknown`."
  @spec parse(String.t()) :: parsed()
  def parse(version) when is_binary(version) do
    with :error <- release(version),
         :error <- dev_on_release(version),
         :error <- dev(version) do
      :unknown
    end
  end

  @doc """
  The release after `tags` (every tag in the repository) on `date`: the day's
  highest number plus one, or `.01` for the day's first.
  """
  @spec next([String.t()], Date.t()) :: String.t()
  def next(tags, %Date{} = date) do
    highest =
      tags
      |> releases()
      |> Enum.filter(fn {day, _number} -> Date.compare(day, date) == :eq end)
      |> Enum.map(fn {_day, number} -> number end)
      |> Enum.max(fn -> 0 end)

    format(date, highest + 1)
  end

  @doc """
  The version of a build: given the tags at its commit, the tags reachable from
  it and its short commit hash (`nil` without git).
  """
  @spec describe([String.t()], [String.t()], String.t() | nil) :: String.t()
  def describe(head_tags, reachable_tags, sha) do
    case {latest(head_tags), latest(reachable_tags)} do
      {{date, number}, _reachable} -> format(date, number)
      {nil, {date, number}} -> "#{format(date, number)}+dev.#{sha || "unknown"}"
      {nil, nil} -> "dev+#{sha || "unknown"}"
    end
  end

  @doc "Orders two releases: by date, then by the day's number."
  @spec compare(String.t(), String.t()) :: :lt | :eq | :gt
  def compare(a, b) do
    {:ok, a} = parse_release(a)
    {:ok, b} = parse_release(b)
    compare_releases(a, b)
  end

  @doc """
  Whether `version` (a runner's) is a release older than `reference`'s (the
  control plane's, or the release a development build of it sits on).
  Development builds, unknown versions and a reference with no release are
  never outdated.
  """
  @spec outdated?(String.t() | nil, String.t()) :: boolean()
  def outdated?(version, reference) when is_binary(version) do
    with {:release, date, number} <- parse(version),
         {:ok, reference} <- reference_release(parse(reference)) do
      compare_releases({date, number}, reference) == :lt
    else
      _not_comparable -> false
    end
  end

  def outdated?(nil, _reference), do: false

  defp reference_release({:release, date, number}), do: {:ok, {date, number}}
  defp reference_release({:dev, {_date, _number} = release, _sha}), do: {:ok, release}
  defp reference_release(_none), do: :error

  defp compare_releases({date_a, number_a}, {date_b, number_b}) do
    case Date.compare(date_a, date_b) do
      :eq when number_a < number_b -> :lt
      :eq when number_a > number_b -> :gt
      order -> order
    end
  end

  defp latest(tags) do
    tags
    |> releases()
    |> Enum.reduce(nil, fn
      release, nil -> release
      release, latest -> if compare_releases(release, latest) == :gt, do: release, else: latest
    end)
  end

  defp releases(tags) do
    Enum.flat_map(tags, fn tag ->
      case parse_tag(tag) do
        {:ok, release} -> [release]
        :error -> []
      end
    end)
  end

  defp release(version) do
    case parse_release(version) do
      {:ok, {date, number}} -> {:release, date, number}
      :error -> :error
    end
  end

  defp dev_on_release(version) do
    with [_all, release, sha] <- Regex.run(@dev_on_release, version),
         {:ok, release} <- parse_release(release) do
      {:dev, release, sha}
    else
      _not_dev -> :error
    end
  end

  defp dev(version) do
    case Regex.run(@dev, version) do
      [_all, sha] -> {:dev, nil, sha}
      nil -> :error
    end
  end

  defp parse_release(version) do
    with [_all, year, month, day, number] <- Regex.run(@release, version),
         {:ok, date} <-
           Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day)),
         number when number > 0 <- String.to_integer(number) do
      {:ok, {date, number}}
    else
      _invalid -> :error
    end
  end
end
