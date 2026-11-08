defmodule PipeMaestro.TestCoverage do
  @moduledoc """
  The coverage tool of the umbrella's apps (`test_coverage: [tool: ...]` in
  each `mix.exs`). It cover-compiles with Mix's own tool
  (`Mix.Tasks.Test.Coverage.start/2`) and reports the same way: a table per
  module, the total, and the exit status 3 under the `summary: [threshold: n]`
  of the app.

  The HTML pages (one per module, in `output`, `cover` by default) are written
  `@html_at_once` modules at a time. Mix's tool writes every module's page at
  once, with two files open per module, which runs out of the 256 file
  descriptors a process gets by default on macOS (`emfile`).
  """

  @html_at_once 16
  @default_threshold 90

  @doc "Cover-compiles `compile_path`; returns what runs once the tests end."
  @spec start(String.t(), keyword()) :: (-> any())
  def start(compile_path, opts) do
    exported = Mix.Tasks.Test.Coverage.start(compile_path, opts)

    if opts[:export] do
      exported
    else
      fn ->
        Mix.shell().info("\nGenerating cover results ...\n")
        results(opts)
      end
    end
  end

  defp results(opts) do
    {:result, lines, _failed} = :cover.analyse(:coverage, :line)
    ignore = opts[:ignore_modules] || []
    modules = Enum.reject(:cover.modules(), &ignored?(&1, ignore))

    if summary = Keyword.get(opts, :summary, true) do
      summary(lines, modules, if(summary == true, do: [], else: summary))
    end

    html(modules, Keyword.get(opts, :output, "cover"))
  end

  defp ignored?(module, ignore),
    do:
      Enum.any?(ignore, fn
        %Regex{} = regex -> Regex.match?(regex, inspect(module))
        other -> other == module
      end)

  defp html(modules, output) do
    File.mkdir_p!(output)

    modules
    |> Enum.chunk_every(@html_at_once)
    |> Enum.each(fn chunk ->
      chunk
      |> Enum.map(fn module ->
        module
        |> :cover.async_analyse_to_file(~c"#{output}/#{module}.html", [:html])
        |> Process.monitor()
      end)
      |> Enum.each(fn ref ->
        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        end
      end)
    end)

    Mix.shell().info("Generated HTML coverage results in #{inspect(output)} directory")
  end

  defp summary(lines, modules, opts) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    {by_module, total} = coverage(lines, modules)

    rows =
      by_module
      |> Enum.map(fn {module, percentage} -> {percentage, inspect(module)} end)
      |> Enum.sort()

    width = rows |> Enum.map(&String.length(elem(&1, 1))) |> Enum.max(fn -> 0 end) |> max(10)
    separator = "|------------|-#{String.duplicate("-", width)}-|"

    Mix.shell().info("| Percentage | #{String.pad_trailing("Module", width)} |")
    Mix.shell().info(separator)
    Enum.each(rows, &row(&1, width))
    Mix.shell().info(separator)
    row({total, "Total"}, width)
    Mix.shell().info("")

    if total < threshold do
      Mix.shell().info("Coverage test failed, threshold not met:\n")
      Mix.shell().info("    Coverage:  #{number(total)}%")
      Mix.shell().info("    Threshold: #{number(threshold)}%")
      Mix.shell().info("")
      System.at_exit(fn _status -> exit({:shutdown, 3}) end)
    end
  end

  # A line counts once, covered if any of its entries ran; line 0 is
  # generated code.
  defp coverage(lines, modules) do
    kept = MapSet.new(modules)

    covered =
      Enum.reduce(lines, %{}, fn {{module, line}, {hit, _miss}}, acc ->
        if line != 0 and module in kept,
          do: Map.update(acc, {module, line}, hit > 0, &(&1 or hit > 0)),
          else: acc
      end)

    grouped = Enum.group_by(covered, fn {{module, _line}, _covered?} -> module end)
    by_module = Map.new(modules, &{&1, percentage(Map.get(grouped, &1, []))})

    {by_module, percentage(covered)}
  end

  defp percentage(entries) do
    {hit, total} =
      Enum.reduce(entries, {0, 0}, fn {_line, covered?}, {hit, total} ->
        {if(covered?, do: hit + 1, else: hit), total + 1}
      end)

    if total == 0, do: 100.0, else: hit / total * 100
  end

  defp row({percentage, name}, width),
    do: Mix.shell().info("| #{number(percentage)}% | #{String.pad_trailing(name, width)} |")

  defp number(value),
    do: (value / 1) |> :erlang.float_to_binary(decimals: 2) |> String.pad_leading(9)
end
