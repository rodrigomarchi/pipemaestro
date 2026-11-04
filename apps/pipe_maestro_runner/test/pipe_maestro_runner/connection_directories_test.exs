defmodule PipeMaestroRunner.ConnectionDirectoriesTest do
  use Slipstream.SocketTest

  alias PipeMaestroRunner.{Connection, Host}

  @config %{
    url: "http://localhost:4000",
    runner_id: "r1",
    runner_name: "build-01",
    token: "cpr_token",
    workspace_name: "Acme",
    workspace_slug: "acme",
    labels: [],
    capacity: nil
  }

  @moduletag :tmp_dir

  # After every join the runner reports its worktrees' disk usage; in test
  # mode the push holds the connection until the test takes it.
  defp assert_usage do
    assert_push("runner:r1", "worktree:usage", %{"count" => 0, "bytes" => 0}, _ref, 5_000)
  end

  test "announces the root's directories and sends them again when they change", %{
    tmp_dir: dir
  } do
    root = Path.join(dir, "src")
    File.mkdir_p!(Path.join(root, "app"))
    {:ok, hello} = Host.hello()

    client =
      start_supervised!(
        {Connection,
         config: @config,
         hello: hello,
         workdir: Path.join(dir, "workdir"),
         root: root,
         rescan_every: 50,
         connect_options: [test_mode?: true]}
      )

    connect_and_assert_join(client, "runner:r1", params, :ok)
    assert_usage()
    assert params["directories"] == [%{"name" => "app", "git" => false}]

    File.mkdir_p!(Path.join(root, "api"))

    assert_push(
      "runner:r1",
      "runner:directories",
      %{"directories" => [%{"name" => "api"}, %{"name" => "app"}]},
      _ref,
      2_000
    )
  end
end
