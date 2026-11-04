defmodule PipeMaestroProtocolTest do
  use ExUnit.Case, async: true

  alias PipeMaestroProtocol.Hello

  describe "constants" do
    test "version, socket, topics and paths" do
      assert PipeMaestroProtocol.version() in PipeMaestroProtocol.supported_versions()
      assert PipeMaestroProtocol.socket_path() == "/runner/socket"
      assert PipeMaestroProtocol.runner_topic("abc") == "runner:abc"
      assert PipeMaestroProtocol.device_code_path() =~ "/device/code"
      assert PipeMaestroProtocol.device_token_path() =~ "/device/token"
    end

    test "parses known error codes and folds unknown ones" do
      for code <- PipeMaestroProtocol.device_errors() do
        assert Atom.to_string(PipeMaestroProtocol.parse_device_error(code)) == code
      end

      assert PipeMaestroProtocol.parse_device_error("nope") == :invalid_request
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

    test "runner_version: a release, a development build or an older form, up to 120 bytes" do
      for version <- ["2026-11-04.01", "2026-11-04.12+dev.abc1234", "dev+abc1234", "0.1.0"] do
        assert {:ok, %Hello{runner_version: ^version}} =
                 Hello.new(Map.put(@valid, :runner_version, version))
      end

      assert {:ok, _hello} =
               Hello.new(Map.put(@valid, :runner_version, String.duplicate("a", 120)))

      assert {:error, "runner_version" <> _} =
               Hello.new(Map.put(@valid, :runner_version, String.duplicate("a", 121)))
    end

    test "rejects missing or malformed fields" do
      assert {:error, "capacity" <> _} = Hello.new(Map.put(@valid, :capacity, 0))
      assert {:error, "hostname" <> _} = Hello.new(Map.delete(@valid, :hostname))
      assert {:error, "labels" <> _} = Hello.new(Map.put(@valid, :labels, ["has space"]))
      assert {:error, "labels" <> _} = Hello.new(Map.put(@valid, :labels, "linux"))
      assert {:error, _} = Hello.new("not a map")
    end

    test "the agent: the CLI's version and how it authenticates" do
      agent = %{"cli_version" => "2.1.317", "auth" => "login"}
      assert {:ok, %Hello{agent: ^agent}} = Hello.new(Map.put(@valid, :agent, agent))
      assert {:ok, %Hello{agent: nil}} = Hello.new(@valid)

      assert {:ok, %Hello{agent: %{"cli_version" => nil, "auth" => "api_key"}}} =
               Hello.new(Map.put(@valid, :agent, %{"auth" => "api_key"}))

      assert {:error, "agent" <> _} = Hello.new(Map.put(@valid, :agent, %{"auth" => "magic"}))
      assert {:error, "agent" <> _} = Hello.new(Map.put(@valid, :agent, "claude"))
    end

    test "directories are validated, deduplicated and sorted" do
      dirs = [
        %{"name" => "b", "git" => false},
        %{name: "a", git: true},
        %{"name" => "a", "git" => true}
      ]

      assert {:ok,
              %Hello{
                directories: [%{"name" => "a", "git" => true}, %{"name" => "b", "git" => false}]
              }} =
               Hello.new(Map.put(@valid, :directories, dirs))

      assert {:ok, %Hello{directories: []}} = Hello.new(@valid)

      for bad <- [
            [%{"name" => ".."}],
            [%{"name" => "a/b", "git" => true}],
            [%{"name" => "a", "git" => "yes"}],
            ["a"],
            "a"
          ] do
        assert {:error, "directories" <> _} = Hello.new(Map.put(@valid, :directories, bad))
      end
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
