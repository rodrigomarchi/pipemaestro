defmodule ClaudeControlPlaneRunner.ConfigTest do
  use ExUnit.Case, async: true

  alias ClaudeControlPlaneRunner.Config

  @moduletag :tmp_dir

  @config %{
    url: "http://localhost:4000",
    runner_id: "abc",
    runner_name: "build-01",
    token: "cpr_secret",
    workspace_name: "Acme",
    workspace_slug: "acme",
    labels: ["gpu"],
    capacity: 2,
    root: "/home/dev/src"
  }

  test "saves, loads and deletes the credentials", %{tmp_dir: dir} do
    assert Config.load(dir) == {:error, :not_found}

    :ok = Config.save(@config, dir)
    assert Config.load(dir) == {:ok, @config}
    assert File.stat!(Config.path(dir)).access in [:read_write, :read]
    assert Bitwise.band(File.stat!(Config.path(dir)).mode, 0o077) == 0

    :ok = Config.delete(dir)
    assert Config.load(dir) == {:error, :not_found}
    assert Config.delete(dir) == :ok
  end

  test "reports corrupt credentials", %{tmp_dir: dir} do
    File.write!(Config.path(dir), "not json")
    assert Config.load(dir) == {:error, :invalid}

    File.write!(Config.path(dir), ~s({"url": "x"}))
    assert Config.load(dir) == {:error, :invalid}

    base = Map.new(Map.drop(@config, [:labels, :capacity]), fn {k, v} -> {to_string(k), v} end)
    File.write!(Config.path(dir), Jason.encode!(Map.put(base, "capacity", 0)))
    assert Config.load(dir) == {:error, :invalid}

    File.write!(Config.path(dir), Jason.encode!(Map.put(base, "labels", [1])))
    assert Config.load(dir) == {:error, :invalid}

    File.write!(Config.path(dir), Jason.encode!(base))
    assert {:ok, %{labels: [], capacity: nil}} = Config.load(dir)
  end

  test "the directory follows RUNNER_CONFIG_DIR" do
    assert Config.dir() =~ "claude-control-plane"
  end
end
