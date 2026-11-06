defmodule PipeMaestroWeb.RunnerLiveTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.{Jobs, Runners, RunnerTelemetry, Tasks}

  setup :register_and_log_in_member

  test "shows the runner's version, marked when older than the runner's required", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    # In tests (config/test.exs) the control plane runs as 2026-11-04.02 and
    # requires runners on 2026-11-03.02.
    {old, _token} =
      runner_fixture(workspace, user, %{name: "antigo", runner_version: "2026-11-03.01"})

    {current, _token} =
      runner_fixture(workspace, user, %{name: "atual", runner_version: "2026-11-03.02"})

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners/#{old.id}")
    assert has_element?(view, "[data-testid=runner-detail-version]", "2026-11-03.01")
    assert has_element?(view, "[data-testid=runner-detail-outdated]", "desatualizado")

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners/#{current.id}")
    assert has_element?(view, "[data-testid=runner-detail-version]", "2026-11-03.02")
    refute has_element?(view, "[data-testid=runner-detail-outdated]")
  end

  test "shows how near the runner's account is to its usage limits", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners/#{runner.id}")
    refute has_element?(view, "[data-testid=runner-rate-limit]")

    {:ok, _} =
      Runners.record_rate_limit(runner, %{
        "status" => "allowed",
        "utilization" => %{"five_hour" => 0.3, "seven_day" => 0.85},
        "resets_at" => 4_102_444_800
      })

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners/#{runner.id}")
    assert has_element?(view, "[data-testid=runner-rate-limit-five_hour]", "30%")
    assert has_element?(view, "[data-testid=runner-rate-limit-seven_day]", "85%")
    assert has_element?(view, "[data-testid=runner-rate-limit-status]", "perto do limite")
    assert has_element?(view, "[data-testid=runner-rate-limit]", "renova 01/01")

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners")
    assert has_element?(view, "[data-testid=runner-near-limit-mac]")
  end

  test "shows a runner: agent, directories, worktrees and its jobs, live", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})

    {:ok, runner} =
      Runners.record_hello(
        runner,
        hello_fixture(%{
          directories: [%{"name" => "app", "git" => true}, %{"name" => "notas", "git" => false}],
          agent: %{"cli_version" => "2.1.317", "auth" => "api_key"}
        })
      )

    {:ok, _} =
      Runners.update_worktree_usage(runner, %{"count" => 2, "bytes" => 2048, "free_bytes" => nil})

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners")

    {:error, {:live_redirect, %{to: path}}} =
      view |> element("[data-testid=runner-link-mac]") |> render_click()

    assert path == "/w/#{workspace.slug}/runners/#{runner.id}"

    {:ok, view, _html} = live(conn, path)
    assert has_element?(view, "[data-testid=runner-detail-agent]", "2.1.317")
    assert has_element?(view, "[data-testid=runner-detail-agent]", "chave de API")
    assert has_element?(view, "[data-testid=runner-detail-directories]", "notas")
    assert has_element?(view, "[data-testid=runner-detail-worktrees]", "2 · 2,0 KB")
    assert has_element?(view, "[data-testid=runner-no-jobs]")

    job = job_fixture(runner, user, %{"prompt" => "investigue o login"})
    assert has_element?(view, "[data-testid=runner-job-#{job.id}]", "investigue o login")
    assert has_element?(view, "[data-testid=runner-job-#{job.id}]", "Na fila")

    {:ok, _} = Jobs.mark_started(runner, job.id)
    assert has_element?(view, "[data-testid=runner-job-#{job.id}]", "Executando")
  end

  test "an admin revokes the runner from its page and goes back to the list", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    {runner, token} = runner_fixture(workspace, user, %{name: "antigo"})

    PipeMaestroWeb.Endpoint.subscribe(PipeMaestroWeb.RunnerStatus.socket_id(runner.id))

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners/#{runner.id}")

    {:ok, list, html} =
      view
      |> element("[data-testid=runner-detail-revoke]")
      |> render_click()
      |> follow_redirect(conn, ~p"/w/#{workspace.slug}/runners")

    assert html =~ "Runner antigo revogado."
    refute has_element?(list, "[data-testid=runner-antigo]")
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    refute Runners.authenticate_runner(token)
  end

  describe "latest jobs" do
    setup %{workspace: workspace, user: user} do
      {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})
      %{runner: runner}
    end

    defp open(ctx), do: live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/runners/#{ctx.runner.id}")

    test "a runner that has not finished any job says so", ctx do
      {:ok, view, _html} = open(ctx)

      assert has_element?(view, "[data-testid=runner-recent-jobs]", "Últimas execuções")

      assert has_element?(
               view,
               "[data-testid=runner-no-recent-jobs]",
               "Este runner ainda não terminou nenhuma execução."
             )
    end

    test "a job the runner finishes shows up live with its numbers", ctx do
      {:ok, view, _html} = open(ctx)
      job = job_fixture(ctx.runner, ctx.user, %{"prompt" => "investigue o login\nem detalhes"})
      {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

      refute has_element?(view, "[data-testid=runner-recent-job-#{job.id}]")
      assert has_element?(view, "[data-testid=runner-job-#{job.id}]")

      {:ok, _} =
        Jobs.finish_job(ctx.runner, job.id, %{
          "status" => "succeeded",
          "cost_usd" => 0.0042,
          "duration_ms" => 1_500,
          "usage" => %{
            "fresh_input" => 100,
            "cache_read" => 2_900,
            "cache_creation" => 0,
            "output" => 500
          }
        })

      row = "[data-testid=runner-recent-job-#{job.id}]"
      assert has_element?(view, row)
      refute has_element?(view, "[data-testid=runner-no-recent-jobs]")

      assert has_element?(
               view,
               "[data-testid=runner-recent-job-link-#{job.id}]",
               "investigue o login"
             )

      assert has_element?(view, "[data-testid=runner-recent-job-status-#{job.id}]", "Concluído")
      assert has_element?(view, "[data-testid=runner-recent-job-duration-#{job.id}]", "1 s")
      assert has_element?(view, "[data-testid=runner-recent-job-cost-#{job.id}]", "US$ 0.0042")
      assert has_element?(view, "[data-testid=runner-recent-job-tokens-#{job.id}]", "3.5k")
      assert has_element?(view, "[data-testid=runner-recent-job-cache-#{job.id}]", "97%")
    end

    test "a job that failed without numbers shows dashes", ctx do
      job = job_fixture(ctx.runner, ctx.user)
      {:ok, _} = Jobs.mark_started(ctx.runner, job.id)
      {:ok, _} = Jobs.finish_job(ctx.runner, job.id, %{"status" => "failed"})

      {:ok, view, _html} = open(ctx)

      assert has_element?(view, "[data-testid=runner-recent-job-status-#{job.id}]", "Falhou")

      for column <- ~w(duration cost tokens cache) do
        assert view
               |> element("[data-testid=runner-recent-job-#{column}-#{job.id}]")
               |> render() =~ "—"
      end
    end

    test "a stage's job shows its task and stage instead of the prompt", ctx do
      runner = with_directories(ctx.runner, [%{"name" => "app", "git" => true}])

      {:ok, task} =
        Tasks.create_task(ctx.user, ctx.workspace, %{
          "title" => "Corrigir login",
          "prompt" => "O botão não responde",
          "pipeline_id" => pipeline_fixture(ctx.workspace).id,
          "project_id" => project_on(runner, "app").id
        })

      [%{job: job}] = task.stage_runs
      {:ok, _} = Jobs.mark_started(runner, job.id)
      {:ok, _} = Jobs.finish_job(runner, job.id, %{"status" => "failed"})

      {:ok, view, _html} = open(ctx)

      assert has_element?(
               view,
               "[data-testid=runner-recent-job-link-#{job.id}]",
               "Corrigir login · Etapa A"
             )
    end

    test "each job leads to its page", ctx do
      job = job_fixture(ctx.runner, ctx.user)
      {:ok, _} = Jobs.mark_started(ctx.runner, job.id)
      {:ok, _} = Jobs.finish_job(ctx.runner, job.id, %{"status" => "succeeded"})

      {:ok, view, _html} = open(ctx)

      assert {:error, {:live_redirect, %{to: path}}} =
               view
               |> element("[data-testid=runner-recent-job-link-#{job.id}]")
               |> render_click()

      assert path == "/w/#{ctx.workspace.slug}/jobs/#{job.id}"
    end

    test "another runner's finished job is not listed", ctx do
      {other, _token} = runner_fixture(ctx.workspace, ctx.user, %{name: "linux"})
      {:ok, view, _html} = open(ctx)

      job = job_fixture(other, ctx.user)
      {:ok, _} = Jobs.mark_started(other, job.id)
      {:ok, _} = Jobs.finish_job(other, job.id, %{"status" => "succeeded"})

      refute has_element?(view, "[data-testid=runner-recent-job-#{job.id}]")
      assert has_element?(view, "[data-testid=runner-no-recent-jobs]")
    end
  end

  describe "tabs" do
    test "the overview is the default; the tabs switch by the URL", %{
      conn: conn,
      workspace: workspace,
      user: user
    } do
      {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners/#{runner.id}")
      assert has_element?(view, "[data-testid=runner-recent-jobs]")
      refute has_element?(view, "[data-testid=runner-connections]")

      view |> element("[data-testid=runner-tab-conexoes]") |> render_click()
      assert_patch(view, ~p"/w/#{workspace.slug}/runners/#{runner.id}?aba=conexoes")
      assert has_element?(view, "[data-testid=runner-connections]")
      refute has_element?(view, "[data-testid=runner-recent-jobs]")

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners/#{runner.id}?aba=nada")
      assert has_element?(view, "[data-testid=runner-recent-jobs]")
    end

    test "connections: uptime, drops and each session with how it ended", %{
      conn: conn,
      workspace: workspace,
      user: user
    } do
      {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})
      now = DateTime.utc_now()

      {:ok, view, _html} =
        live(conn, ~p"/w/#{workspace.slug}/runners/#{runner.id}?aba=conexoes")

      assert has_element?(view, "[data-testid=runner-no-sessions]")

      session = RunnerTelemetry.open_session(runner, DateTime.add(now, -2, :hour))
      RunnerTelemetry.close_session(session.id, "crashed", DateTime.add(now, -1, :hour))

      RunnerTelemetry.record_refusal(
        runner,
        "outdated",
        "2026-01-01.01",
        DateTime.add(now, -30, :minute)
      )

      RunnerTelemetry.open_session(runner, DateTime.add(now, -10, :minute))

      {:ok, view, _html} =
        live(conn, ~p"/w/#{workspace.slug}/runners/#{runner.id}?aba=conexoes")

      assert has_element?(view, "[data-testid=runner-drops-day]", "1")
      assert has_element?(view, "[data-testid=runner-session-reason]", "erro no canal")
      assert has_element?(view, "[data-testid=runner-session-reason]", "recusado: versão")
      assert has_element?(view, "[data-testid=runner-session-reason]", "conectado")
      assert view |> element("[data-testid=runner-uptime-day]") |> render() =~ "%"

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners")
      assert has_element?(view, "[data-testid=runner-uptime-mac]", "uptime 7d")
    end
  end

  test "another workspace's runner is not found", %{conn: conn, workspace: workspace} do
    other = workspace_fixture()
    {runner, _token} = runner_fixture(other, member_fixture(other))

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/w/#{workspace.slug}/runners/#{runner.id}")
    end
  end
end
