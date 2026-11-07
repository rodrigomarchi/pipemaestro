defmodule PipeMaestroRunner.InstanceLockTest do
  use ExUnit.Case, async: true

  alias PipeMaestroRunner.InstanceLock

  @moduletag :tmp_dir

  test "with no runner holding it, it is taken at once", %{tmp_dir: dir} do
    path = Path.join(dir, "runner.pid")

    assert InstanceLock.acquire(path, pid: "100") == :ok
    assert File.read!(path) == "100"
  end

  test "a runner that is gone does not hold it", %{tmp_dir: dir} do
    path = Path.join(dir, "runner.pid")
    File.write!(path, "99")

    assert InstanceLock.acquire(path, pid: "100", alive?: fn "99" -> false end) == :ok
    assert File.read!(path) == "100"
  end

  test "waits for the runner on its way out, then takes it", %{tmp_dir: dir} do
    path = Path.join(dir, "runner.pid")
    File.write!(path, "99")
    gone_at = System.monotonic_time(:millisecond) + 400
    alive? = fn "99" -> System.monotonic_time(:millisecond) < gone_at end

    assert InstanceLock.acquire(path, pid: "100", alive?: alive?) == :ok
    assert System.monotonic_time(:millisecond) >= gone_at
    assert File.read!(path) == "100"
  end

  test "a runner that stays past the wait keeps it", %{tmp_dir: dir} do
    path = Path.join(dir, "runner.pid")
    File.write!(path, "99")

    assert InstanceLock.acquire(path, pid: "100", alive?: fn _pid -> true end, wait_ms: 300) ==
             {:error, {:held, "99"}}

    assert File.read!(path) == "99"
  end

  test "this runner's own pid, alive, is checked with the system" do
    path = Path.join(System.tmp_dir!(), "runner-#{System.unique_integer([:positive])}.pid")
    on_exit(fn -> File.rm(path) end)
    File.write!(path, System.pid())

    assert InstanceLock.acquire(path, pid: "1", wait_ms: 300) == {:error, {:held, System.pid()}}
  end

  test "release/2 takes away only its own lock", %{tmp_dir: dir} do
    path = Path.join(dir, "runner.pid")
    File.write!(path, "99")

    assert InstanceLock.release(path, "100") == :ok
    assert File.exists?(path)

    assert InstanceLock.release(path, "99") == :ok
    refute File.exists?(path)
  end
end
