defmodule PipeMaestroWeb.RunnersLiveTest do
  use PipeMaestroWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PipeMaestro.Runners
  alias PipeMaestroWeb.RunnerStatus

  setup :register_and_log_in_member

  test "explains how to connect when there are no runners", %{conn: conn, workspace: workspace} do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners")
    assert has_element?(view, "[data-testid=no-runners]")

    view |> element("[data-testid=connect-runner]") |> render_click()

    assert view |> element("[data-testid=connect-login-command]") |> render() =~
             "runner.login URL="

    render_click(view, "close_connect")
    refute has_element?(view, "[data-testid=connect-login-command]")
  end

  test "without published binaries there are no download links", %{
    conn: conn,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners")
    refute has_element?(view, "[data-testid=runner-downloads]")
  end

  describe "with the runner's binaries published" do
    setup do
      Application.put_env(:pipe_maestro_web, :runner_downloads_url, "/downloads/runner")
      on_exit(fn -> Application.delete_env(:pipe_maestro_web, :runner_downloads_url) end)
    end

    test "links each platform's binary and the install command", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners")

      for target <- ~w(macos_arm64 macos_x86_64 linux_x86_64 linux_arm64) do
        assert view
               |> element("[data-testid=runner-download-#{target}]")
               |> render() =~ ~s(href="/downloads/runner/pipemaestro_#{target}")
      end

      assert has_element?(
               view,
               "[data-testid=runner-download-version]",
               PipeMaestro.Version.version()
             )

      assert view |> element("[data-testid=runner-download-command]") |> render() =~
               PipeMaestroWeb.Endpoint.url() <> "/downloads/runner/pipemaestro_macos_arm64"
    end

    test "connecting a runner means downloading it and signing in", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners")
      view |> element("[data-testid=connect-runner]") |> render_click()

      # This platform is not the default one, so the login names it.
      assert view |> element("[data-testid=connect-login-command]") |> render() =~
               "pipemaestro login --url #{PipeMaestroWeb.Endpoint.url()}"
    end

    test "on the default platform the login needs no --url" do
      html =
        render_component(&PipeMaestroWeb.RunnerComponents.connect_instructions/1,
          url: PipeMaestroProtocol.default_platform_url(),
          downloads: "/downloads/runner",
          version: "2026-11-04.02"
        )

      assert html =~ "pipemaestro login</pre>"
      refute html =~ "--url"
    end
  end

  test "shows each runner's version and marks the ones older than the control plane", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    # The control plane runs as 2026-11-04.02 in tests (config/test.exs).
    runner_fixture(workspace, user, %{name: "antigo", runner_version: "2026-11-04.01"})
    runner_fixture(workspace, user, %{name: "atual", runner_version: "2026-11-04.02"})
    runner_fixture(workspace, user, %{name: "dev", runner_version: "2026-11-04.01+dev.abc1234"})
    runner_fixture(workspace, user, %{name: "legado", runner_version: "0.1.0"})

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners")

    assert has_element?(view, "[data-testid=runner-version-antigo]", "2026-11-04.01")
    assert has_element?(view, "[data-testid=runner-outdated-antigo]", "desatualizado")

    assert has_element?(view, "[data-testid=runner-version-atual]", "2026-11-04.02")
    refute has_element?(view, "[data-testid=runner-outdated-atual]")

    assert has_element?(view, "[data-testid=runner-version-dev]", "2026-11-04.01+dev.abc1234")
    refute has_element?(view, "[data-testid=runner-outdated-dev]")

    assert has_element?(view, "[data-testid=runner-version-legado]", "0.1.0")
    refute has_element?(view, "[data-testid=runner-outdated-legado]")
  end

  test "lists the workspace's runners and only those", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    {runner, _token} =
      runner_fixture(workspace, user, %{name: "build-01", labels: ["docker"], capacity: 6})

    {:ok, _runner} =
      PipeMaestro.Runners.update_worktree_usage(runner, %{
        "count" => 3,
        "bytes" => 1_610_612_736,
        "free_bytes" => 53_687_091_200
      })

    other = workspace_fixture()
    runner_fixture(other, member_fixture(other), %{name: "alheio"})

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners")

    assert has_element?(view, "[data-testid=runner-build-01]")
    assert has_element?(view, "[data-testid=runner-status-build-01]", "Offline")
    assert has_element?(view, "[data-testid=runner-labels-build-01]", "docker")
    assert has_element?(view, "[data-testid=runner-capacity-build-01]", "6")
    assert has_element?(view, "[data-testid=runner-directories-build-01]", "sem raiz")
    assert has_element?(view, "[data-testid=runner-worktrees-build-01]", "3 · 1,5 GB")
    assert has_element?(view, "[data-testid=runner-worktrees-build-01]", "50 GB livres")
    assert has_element?(view, "[data-testid=runner-agent-build-01]", "—")

    {:ok, _} =
      PipeMaestro.Runners.record_hello(
        PipeMaestro.Runners.get_runner!(workspace, runner.id),
        hello_fixture(%{agent: %{"cli_version" => "2.1.317", "auth" => "login"}})
      )

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners")
    assert has_element?(view, "[data-testid=runner-agent-build-01]", "2.1.317")
    assert has_element?(view, "[data-testid=runner-agent-build-01]", "login pessoal")
    refute has_element?(view, "[data-testid=runner-alheio]")
  end

  test "turns a runner online and back offline live", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    {runner, _token} = runner_fixture(workspace, user, %{name: "build-01"})
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners")

    tracker = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, _ref} = RunnerStatus.track(tracker, runner)

    assert eventually(fn ->
             has_element?(view, "[data-testid=runner-status-build-01]", "Online")
           end)

    assert has_element?(view, "[data-testid=online-count]", "1 online")

    Process.exit(tracker, :kill)

    assert eventually(fn ->
             has_element?(view, "[data-testid=runner-status-build-01]", "Offline")
           end)
  end

  test "renames a runner", %{conn: conn, workspace: workspace, user: user} do
    runner_fixture(workspace, user, %{name: "build-01"})
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners")

    view |> element("[data-testid=runner-rename-build-01]") |> render_click()

    assert view |> form("#rename-form", runner: %{name: ""}) |> render_submit() =~
             "não pode ficar em branco"

    html = view |> form("#rename-form", runner: %{name: "Servidor A"}) |> render_submit()

    assert html =~ "Runner renomeado para Servidor A."
    assert has_element?(view, ~s([data-testid="runner-Servidor A"]))
    render_click(view, "open_rename", %{"id" => hd(Runners.list_runners(workspace)).id})
    render_click(view, "close_rename")
    refute has_element?(view, "#rename-form")
  end

  test "revokes a runner and closes its connection", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    {runner, token} = runner_fixture(workspace, user, %{name: "build-01"})
    PipeMaestroWeb.Endpoint.subscribe(RunnerStatus.socket_id(runner.id))
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners")

    assert view |> element("[data-testid=runner-revoke-build-01]") |> render_click() =~
             "Runner build-01 revogado."

    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    refute Runners.authenticate_runner(token)
    refute has_element?(view, "[data-testid=runner-build-01]")
  end

  test "the sidebar leads here", %{conn: conn, workspace: workspace} do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}")

    assert view |> element("[data-testid=sidebar-runners]") |> render() =~
             ~s(href="/w/#{workspace.slug}/runners")
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end
end
