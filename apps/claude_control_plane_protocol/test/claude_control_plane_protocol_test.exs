defmodule ClaudeControlPlaneProtocolTest do
  use ExUnit.Case, async: true

  alias ClaudeControlPlaneProtocol.Hello

  describe "constants" do
    test "version, socket, topics and paths" do
      assert ClaudeControlPlaneProtocol.version() in ClaudeControlPlaneProtocol.supported_versions()
      assert ClaudeControlPlaneProtocol.socket_path() == "/runner/socket"
      assert ClaudeControlPlaneProtocol.runner_topic("abc") == "runner:abc"
      assert ClaudeControlPlaneProtocol.device_code_path() =~ "/device/code"
      assert ClaudeControlPlaneProtocol.device_token_path() =~ "/device/token"
    end

    test "parses known error codes and folds unknown ones" do
      for code <- ClaudeControlPlaneProtocol.device_errors() do
        assert Atom.to_string(ClaudeControlPlaneProtocol.parse_device_error(code)) == code
      end

      assert ClaudeControlPlaneProtocol.parse_device_error("nope") == :invalid_request
    end
  end

  describe "Hello" do
    @valid %{
      protocol_version: 1,
      runner_version: "0.1.0",
      hostname: "build-01",
      os: "linux",
      arch: "x86_64",
      labels: ["Linux", "elixir", "elixir"],
      capacity: 4
    }

    test "validates, normalizes labels and round-trips through the wire form" do
      assert {:ok, hello} = Hello.new(@valid)
      assert hello.labels == ["elixir", "linux"]

      wire = Hello.to_map(hello)
      assert wire["hostname"] == "build-01"
      assert Hello.from_map(wire) == {:ok, hello}
    end

    test "rejects missing or malformed fields" do
      assert {:error, "capacity" <> _} = Hello.new(Map.put(@valid, :capacity, 0))
      assert {:error, "hostname" <> _} = Hello.new(Map.delete(@valid, :hostname))
      assert {:error, "labels" <> _} = Hello.new(Map.put(@valid, :labels, ["has space"]))
      assert {:error, "labels" <> _} = Hello.new(Map.put(@valid, :labels, "linux"))
      assert {:error, _} = Hello.new("not a map")
    end

    test "running_job_ids defaults to none and is validated" do
      assert {:ok, %Hello{running_job_ids: []}} = Hello.new(@valid)

      assert {:ok, %Hello{running_job_ids: ["job-1"]} = hello} =
               Hello.new(Map.put(@valid, :running_job_ids, ["job-1"]))

      assert Hello.to_map(hello)["running_job_ids"] == ["job-1"]
      assert {:error, "running_job_ids" <> _} = Hello.new(Map.put(@valid, :running_job_ids, [1]))
      assert {:error, "running_job_ids" <> _} = Hello.new(Map.put(@valid, :running_job_ids, "x"))
    end
  end
end
