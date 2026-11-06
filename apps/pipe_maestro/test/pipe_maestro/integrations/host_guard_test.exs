defmodule PipeMaestro.Integrations.HostGuardTest do
  # It changes the application's configuration.
  use ExUnit.Case, async: false

  alias PipeMaestro.Integrations.{Connection, HostGuard}

  setup do
    config = Application.get_env(:pipe_maestro, PipeMaestro.Integrations)

    Application.put_env(
      :pipe_maestro,
      PipeMaestro.Integrations,
      Keyword.put(config, :allow_private_hosts, false)
    )

    on_exit(fn -> Application.put_env(:pipe_maestro, PipeMaestro.Integrations, config) end)
  end

  test "refuses the platform's own network" do
    for url <-
          ~w(http://127.0.0.1:4000 https://10.0.0.5 https://192.168.1.10 https://172.20.0.1 https://169.254.169.254/latest https://[::1] https://[fd00::1] https://localhost) do
      assert {:error, _} = HostGuard.check(url), url
    end
  end

  test "takes a public address" do
    assert HostGuard.check("https://8.8.8.8") == :ok
    assert HostGuard.private?({8, 8, 8, 8}) == false
    assert HostGuard.private?({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001})
  end

  test "a connection to a local host over http needs private hosts allowed" do
    attrs = %{
      "name" => "a",
      "provider" => "forgejo",
      "auth_kind" => "token",
      "token" => "t",
      "base_url" => "http://localhost:3000"
    }

    refute Connection.changeset(%Connection{}, attrs).valid?
  end
end
