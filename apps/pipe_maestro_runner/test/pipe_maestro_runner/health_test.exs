defmodule PipeMaestroRunner.HealthTest do
  use ExUnit.Case, async: true

  alias PipeMaestroProtocol.RunnerHealth
  alias PipeMaestroRunner.Health

  @df """
  Filesystem 1024-blocks      Used Available Capacity  Mounted on
  /dev/disk3s5 971350180 512345678 400000000    57%    /System/Volumes/Data
  """

  @vm_stat """
  Mach Virtual Memory Statistics: (page size of 16384 bytes)
  Pages free:                               12345.
  Pages active:                            100000.
  Pages inactive:                           90000.
  Pages wired down:                         50000.
  Pages occupied by compressor:             10000.
  """

  defp darwin_cmd("sysctl", ["-n", "hw.memsize"], _opts), do: {"17179869184\n", 0}
  defp darwin_cmd("sysctl", ["-n", "hw.ncpu"], _opts), do: {"8\n", 0}
  defp darwin_cmd("sysctl", ["-n", "vm.loadavg"], _opts), do: {"{ 2.50 1.75 1.20 }\n", 0}
  defp darwin_cmd("vm_stat", [], _opts), do: {@vm_stat, 0}
  defp darwin_cmd("ps", ["-A", "-o", "%cpu"], _opts), do: {" %CPU\n 200.0\n  40.0\n   0.0\n", 0}
  defp darwin_cmd("df", ["-k", "/work"], _opts), do: {@df, 0}

  test "macOS: load, memory, CPU over the CPUs and the working directory's disk" do
    {sample, nil} =
      Health.sample(
        os: :darwin,
        cmd: &darwin_cmd/3,
        workdir: "/work",
        outbox_pending: 3,
        running_jobs: 1
      )

    assert sample["load1"] == 2.5
    assert sample["mem_total_bytes"] == 17_179_869_184
    assert sample["mem_used_bytes"] == 160_000 * 16_384
    assert sample["cpu_pct"] == 30.0
    assert sample["disk_total_bytes"] == 971_350_180 * 1024
    assert sample["disk_free_bytes"] == 400_000_000 * 1024
    assert sample["outbox_pending"] == 3
    assert sample["running_jobs"] == 1
    assert sample["beam_bytes"] > 0

    # What the runner sends is what the control plane accepts.
    assert {:ok, _sample} = RunnerHealth.parse(sample)
  end

  @meminfo """
  MemTotal:       16000000 kB
  MemFree:         2000000 kB
  MemAvailable:   12000000 kB
  """

  defp proc(stat) do
    fn
      "/proc/loadavg" -> {:ok, "0.75 0.50 0.25 1/234 5678\n"}
      "/proc/meminfo" -> {:ok, @meminfo}
      "/proc/stat" -> {:ok, stat}
    end
  end

  test "Linux: the CPU share is the busy time since the previous sample" do
    first = "cpu  100 0 100 700 100 0 0 0 0 0\ncpu0 1 2 3\n"
    second = "cpu  200 0 200 1300 300 0 0 0 0 0\n"

    {sample, cpu} = Health.sample(os: :linux, read: proc(first), cmd: fn _, _, _ -> {"", 1} end)
    assert sample["cpu_pct"] == nil
    assert sample["load1"] == 0.75
    assert sample["mem_total_bytes"] == 16_000_000 * 1024
    assert sample["mem_used_bytes"] == 4_000_000 * 1024
    assert sample["disk_free_bytes"] == nil

    {sample, _cpu} = Health.sample(os: :linux, read: proc(second), cpu: cpu)
    # 200 busy out of 1000.
    assert sample["cpu_pct"] == 20.0
  end

  test "what the machine does not tell is nil" do
    failing = fn _command, _args, _opts -> {"", 1} end
    {sample, nil} = Health.sample(os: :darwin, cmd: failing, workdir: "/work")
    assert sample["cpu_pct"] == nil
    assert sample["mem_used_bytes"] == nil
    assert sample["disk_total_bytes"] == nil

    {sample, nil} = Health.sample(os: :other)
    assert sample["load1"] == nil
    assert {:ok, _sample} = RunnerHealth.parse(sample)
  end

  test "a command this machine does not have counts as unknown" do
    {sample, nil} = Health.sample(os: :darwin, cmd: &System.cmd/3)
    assert is_map(sample)

    missing = fn command, args, opts ->
      System.cmd("pipemaestro-no-such-" <> command, args, opts)
    end

    {sample, nil} = Health.sample(os: :darwin, cmd: missing)
    assert sample["load1"] == nil
  end
end
