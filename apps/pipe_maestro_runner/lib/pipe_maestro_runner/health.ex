defmodule PipeMaestroRunner.Health do
  @moduledoc """
  How this machine is doing, in the wire form of
  `PipeMaestroProtocol.RunnerHealth`: CPU, load, memory and the disk of
  the working directory, read with the system's own tools, plus what the
  caller knows (the outbox and the jobs running) and the VM's memory.

    * macOS: `sysctl` (load, memory size, CPUs), `vm_stat` (memory in use:
      active, wired and compressed pages) and `ps` (CPU, the processes'
      shares summed over the CPUs);
    * Linux: `/proc/loadavg`, `/proc/meminfo` (total minus available) and
      `/proc/stat`, whose CPU share is the busy time since the previous
      sample: the caller passes back the `cpu` state each sample returns, and
      the first one has no CPU share;
    * both: `df -k` on the working directory.

  A value the machine does not tell is `nil`. Runs commands: call it off any
  process that must stay responsive.
  """

  @typedoc "What a Linux sample keeps to compute the next one's CPU share."
  @type cpu_state :: {busy :: non_neg_integer(), total :: non_neg_integer()} | nil

  @doc """
  A sample as of now. Options:

    * `:workdir` — whose disk is measured;
    * `:outbox_pending`, `:running_jobs` — passed through;
    * `:cpu` — the state the previous sample returned (Linux);
    * `:os` — `:darwin`, `:linux` or anything else (default: this machine);
    * `:cmd` — runs a command, as `System.cmd/3` (for tests);
    * `:read` — reads a file, as `File.read/1` (for tests).

  Returns the sample and the CPU state for the next one.
  """
  @spec sample(keyword()) :: {map(), cpu_state()}
  def sample(opts \\ []) do
    os = Keyword.get_lazy(opts, :os, &os/0)
    cmd = Keyword.get(opts, :cmd, &System.cmd/3)
    read = Keyword.get(opts, :read, &File.read/1)

    {machine, cpu} = machine(os, cmd, read, Keyword.get(opts, :cpu))
    {disk_total, disk_free} = disk(cmd, Keyword.get(opts, :workdir))

    sample =
      Map.merge(machine, %{
        "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "disk_total_bytes" => disk_total,
        "disk_free_bytes" => disk_free,
        "outbox_pending" => Keyword.get(opts, :outbox_pending),
        "running_jobs" => Keyword.get(opts, :running_jobs),
        "beam_bytes" => :erlang.memory(:total)
      })

    {sample, cpu}
  end

  defp os do
    case :os.type() do
      {:unix, :darwin} -> :darwin
      {:unix, :linux} -> :linux
      _other -> :other
    end
  end

  defp machine(:darwin, cmd, _read, _cpu) do
    total = cmd |> run("sysctl", ["-n", "hw.memsize"]) |> integer()
    cpus = cmd |> run("sysctl", ["-n", "hw.ncpu"]) |> integer()

    {%{
       "load1" => cmd |> run("sysctl", ["-n", "vm.loadavg"]) |> darwin_load(),
       "mem_total_bytes" => total,
       "mem_used_bytes" => cmd |> run("vm_stat", []) |> vm_stat_used(),
       "cpu_pct" => cmd |> run("ps", ["-A", "-o", "%cpu"]) |> ps_cpu(cpus)
     }, nil}
  end

  defp machine(:linux, _cmd, read, previous) do
    {total, available} = read |> read_file("/proc/meminfo") |> meminfo()
    {cpu_pct, cpu} = read |> read_file("/proc/stat") |> proc_stat(previous)

    {%{
       "load1" => read |> read_file("/proc/loadavg") |> first_float(),
       "mem_total_bytes" => total,
       "mem_used_bytes" => if(total && available, do: max(total - available, 0)),
       "cpu_pct" => cpu_pct
     }, cpu}
  end

  defp machine(_os, _cmd, _read, _cpu),
    do:
      {%{"load1" => nil, "mem_total_bytes" => nil, "mem_used_bytes" => nil, "cpu_pct" => nil},
       nil}

  defp disk(_cmd, nil), do: {nil, nil}

  defp disk(cmd, workdir) do
    with output when is_binary(output) <- run(cmd, "df", ["-k", workdir]),
         [_fs, total, _used, free | _rest] <-
           output |> String.split("\n", trim: true) |> List.last("") |> String.split() do
      {kilobytes(total), kilobytes(free)}
    else
      _unknown -> {nil, nil}
    end
  end

  defp run(cmd, command, args) do
    case cmd.(command, args, stderr_to_stdout: true) do
      {output, 0} -> output
      _failed -> nil
    end
  rescue
    # A command this machine does not have.
    ErlangError -> nil
  end

  defp read_file(read, path) do
    case read.(path) do
      {:ok, content} -> content
      _error -> nil
    end
  end

  # "{ 1.23 1.10 1.00 }"
  defp darwin_load(nil), do: nil
  defp darwin_load(output), do: output |> String.replace(["{", "}"], "") |> first_float()

  # The pages in use: active, wired and held by the compressor.
  defp vm_stat_used(nil), do: nil

  defp vm_stat_used(output) do
    page =
      case Regex.run(~r/page size of (\d+) bytes/, output) do
        [_, size] -> String.to_integer(size)
        nil -> 4096
      end

    pages =
      for label <- ["Pages active", "Pages wired down", "Pages occupied by compressor"],
          [_, count] <- [Regex.run(~r/#{label}:\s+(\d+)/, output)],
          do: String.to_integer(count)

    if pages == [], do: nil, else: Enum.sum(pages) * page
  end

  defp ps_cpu(nil, _cpus), do: nil
  defp ps_cpu(_output, nil), do: nil

  defp ps_cpu(output, cpus) do
    sum =
      output
      |> String.split("\n", trim: true)
      |> Enum.drop(1)
      |> Enum.map(&parse_float/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    (sum / max(cpus, 1)) |> min(100.0) |> Float.round(1)
  end

  defp meminfo(nil), do: {nil, nil}

  defp meminfo(content) do
    kb = fn key ->
      case Regex.run(~r/^#{key}:\s+(\d+) kB/m, content) do
        [_, value] -> String.to_integer(value) * 1024
        nil -> nil
      end
    end

    {kb.("MemTotal"), kb.("MemAvailable")}
  end

  # The first line adds up the CPUs' time: user nice system idle iowait irq
  # softirq steal; idle and iowait are the time not busy.
  defp proc_stat(nil, _previous), do: {nil, nil}

  defp proc_stat(content, previous) do
    with ["cpu" | fields] <- content |> String.split("\n") |> List.first("") |> String.split(),
         numbers when length(numbers) >= 4 <-
           Enum.map(fields, &integer/1) |> Enum.reject(&is_nil/1) do
      total = Enum.sum(Enum.take(numbers, 8))
      idle = Enum.at(numbers, 3) + (Enum.at(numbers, 4) || 0)
      state = {total - idle, total}
      {cpu_share(previous, state), state}
    else
      _unknown -> {nil, nil}
    end
  end

  defp cpu_share({busy0, total0}, {busy1, total1}) when total1 > total0,
    do: ((busy1 - busy0) / (total1 - total0) * 100) |> max(0.0) |> min(100.0) |> Float.round(1)

  defp cpu_share(_previous, _state), do: nil

  defp first_float(nil), do: nil
  defp first_float(text), do: text |> String.split() |> List.first() |> parse_float()

  defp parse_float(nil), do: nil

  defp parse_float(text) do
    case Float.parse(String.trim(text)) do
      {value, _rest} -> value
      :error -> nil
    end
  end

  defp integer(nil), do: nil

  defp integer(text) do
    case Integer.parse(String.trim(text)) do
      {value, _rest} -> value
      :error -> nil
    end
  end

  defp kilobytes(text) do
    case integer(text) do
      nil -> nil
      kb -> kb * 1024
    end
  end
end
