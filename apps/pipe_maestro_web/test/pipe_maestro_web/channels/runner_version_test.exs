defmodule PipeMaestroWeb.RunnerVersionTest do
  # Turns the runner version rule on, which is global to the VM.
  use PipeMaestroWeb.ChannelCase, async: false

  import Phoenix.ConnTest, only: [build_conn: 0, post: 3, json_response: 2]

  alias PipeMaestro.{Jobs, Runners}
  alias PipeMaestroProtocol.Hello
  alias PipeMaestroWeb.{RunnerChannel, RunnerSocket, RunnerStatus}

  @endpoint PipeMaestroWeb.Endpoint
  # The runner's version the control plane requires in tests (config/test.exs),
  # and the control plane's own, which differs.
  @current "2026-11-03.02"
  @control_plane "2026-11-04.02"

  setup do
    previous = Application.get_env(:pipe_maestro, :runner_version_policy)
    Application.put_env(:pipe_maestro, :runner_version_policy, :exact)
    on_exit(fn -> Application.put_env(:pipe_maestro, :runner_version_policy, previous) end)

    workspace = workspace_fixture()
    user = member_fixture(workspace)

    {runner, token} =
      runner_fixture(workspace, user, %{name: "build-01", runner_version: @current})

    {:ok, socket} =
      connect(RunnerSocket, %{
        "token" => token,
        "protocol_version" => to_string(PipeMaestroProtocol.version())
      })

    %{workspace: workspace, user: user, runner: runner, socket: socket}
  end

  defp hello(version), do: Hello.to_map(hello_fixture(%{runner_version: version}))

  test "a runner on another version is refused on joining, told where to download", ctx do
    job = job_fixture(ctx.runner, ctx.user)

    assert {:error, refusal} =
             subscribe_and_join(
               ctx.socket,
               RunnerChannel,
               "runner:" <> ctx.runner.id,
               hello("2026-11-03.01")
             )

    assert refusal == %{
             "reason" => "outdated",
             "version" => @current,
             "runner_version" => "2026-11-03.01",
             "download_url" => PipeMaestroWeb.Endpoint.url()
           }

    # Nothing of it is recorded, and it is not online: its queued job waits.
    refute MapSet.member?(RunnerStatus.online_ids(ctx.workspace.id), ctx.runner.id)
    assert Runners.get_runner!(ctx.workspace, ctx.runner.id).runner_version == @current
    assert Jobs.get_job!(ctx.workspace, job.id).status == :queued
  end

  test "a runner on the control plane's version is refused, told the runner's version", ctx do
    assert {:error, %{"reason" => "outdated", "version" => @current} = refusal} =
             subscribe_and_join(
               ctx.socket,
               RunnerChannel,
               "runner:" <> ctx.runner.id,
               hello(@control_plane)
             )

    assert refusal["runner_version"] == @control_plane
  end

  test "a runner on the current version joins", ctx do
    assert {:ok, _reply, _channel} =
             subscribe_and_join(
               ctx.socket,
               RunnerChannel,
               "runner:" <> ctx.runner.id,
               hello(@current)
             )
  end

  test "the refusal names the published downloads when there are some" do
    Application.put_env(:pipe_maestro_web, :runner_downloads_url, "/downloads/runner")
    on_exit(fn -> Application.delete_env(:pipe_maestro_web, :runner_downloads_url) end)

    assert PipeMaestroWeb.RunnerUpdate.refusal("x", @current)["download_url"] ==
             PipeMaestroWeb.Endpoint.url() <> "/downloads/runner/"
  end

  test "an outdated runner cannot even sign in" do
    body =
      build_conn()
      |> post("/api/runner/device/code", %{hello: hello(@control_plane)})
      |> json_response(409)

    assert %{"error" => "outdated", "version" => @current, "runner_version" => @control_plane} =
             body

    assert body["download_url"]

    assert build_conn()
           |> post("/api/runner/device/code", %{hello: hello(@current)})
           |> json_response(200)
           |> Map.has_key?("user_code")
  end
end
