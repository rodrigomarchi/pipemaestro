defmodule PipeMaestroWeb.ProposalLiveTest do
  use PipeMaestroWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PipeMaestro.{Jobs, Pipelines, Projects, Proposals, Runners}
  alias PipeMaestroWeb.RunnerStatus

  @directories [%{"name" => "app", "git" => true}, %{"name" => "notas", "git" => false}]

  @output %{
    "analise" => "Um app **Phoenix**.",
    "verificacoes" => [
      %{"comando" => "mix test", "passou" => true},
      %{"comando" => "mix credo", "passou" => false, "observacao" => "2 avisos"}
    ],
    "projeto" => %{"nome" => "App", "teste" => "mix test", "copy_paths" => ["deps"]},
    "pipeline" => %{
      "name" => "Entrega do App",
      "delivery" => "pr",
      "stages" => [
        %{"key" => "plano", "name" => "Plano", "prompt" => "Planeje: {{tarefa.descricao}}"},
        %{
          "key" => "codigo",
          "name" => "Código",
          "prompt" => "Implemente.",
          "gates" => ["{{projeto.teste}}"],
          "max_attempts" => 3
        }
      ]
    }
  }

  setup :register_and_log_in_member

  setup %{workspace: workspace, user: user} do
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})

    {:ok, runner} =
      Runners.record_hello(
        runner,
        hello_fixture(%{directories: @directories, capabilities: ["scratch"]})
      )

    {old, _token} = runner_fixture(workspace, user, %{name: "antigo"})
    %{runner: runner, old: with_directories(old, @directories)}
  end

  defp bring_online(runner) do
    test_pid = self()

    spawn_link(fn ->
      {:ok, _ref} = RunnerStatus.track(self(), runner)
      send(test_pid, :tracked)
      Process.sleep(:infinity)
    end)

    assert_receive :tracked
  end

  defp proposal(ctx) do
    {:ok, job} =
      Proposals.request(ctx.user, ctx.workspace, %{
        "runner_id" => ctx.runner.id,
        "directory" => "app",
        "request" => "Entregar *issues* com PR"
      })

    job
  end

  defp finish(ctx, job, attrs) do
    {:ok, _started} = Jobs.mark_started(ctx.runner, job.id)
    {:ok, job} = Jobs.finish_job(ctx.runner, job.id, attrs)
    job
  end

  test "asks a capable runner to study one of its git directories", ctx do
    bring_online(ctx.runner)
    bring_online(ctx.old)
    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/pipelines")

    view |> element("[data-testid=generate-pipeline]") |> render_click()
    runners = view |> element("[data-testid=generate-runner]") |> render()
    assert runners =~ "mac"
    assert runners =~ ~r/<option disabled[^>]*>antigo \(atualize o runner\)/

    view |> form("#generate-form", proposal: %{runner_id: ctx.runner.id}) |> render_change()
    directories = view |> element("[data-testid=generate-directory]") |> render()
    assert directories =~ "app"
    refute directories =~ "notas"

    {:error, {:live_redirect, %{to: path}}} =
      view
      |> form("#generate-form",
        proposal: %{runner_id: ctx.runner.id, directory: "app", request: "Entregar com PR"}
      )
      |> render_submit()

    [job] = Proposals.list_recent(ctx.workspace)
    assert path == ~p"/w/#{ctx.workspace.slug}/pipelines/proposals/#{job.id}"
    assert job.context["scratch"] == true
  end

  test "a request without a runner or text shows what is missing", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/pipelines")
    view |> element("[data-testid=generate-pipeline]") |> render_click()
    assert has_element?(view, "[data-testid=generate-no-runners]")

    html = view |> form("#generate-form", proposal: %{request: ""}) |> render_submit()
    assert html =~ "escolha um runner online"
    assert html =~ "conte o que o pipeline deve fazer"
  end

  test "follows the analysis live, then shows what it proposed", ctx do
    job = proposal(ctx)
    {:ok, index, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/pipelines")
    assert has_element?(index, "[data-testid=proposal-status-#{job.id}]", "Na fila")

    {:ok, view, _html} =
      live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/pipelines/proposals/#{job.id}")

    assert has_element?(view, "[data-testid=proposal-directory]", "app")
    assert has_element?(view, "[data-testid=proposal-request] em", "issues")
    assert has_element?(view, "[data-testid=proposal-waiting]")
    assert has_element?(view, "[data-testid=proposal-cancel]")

    finish(ctx, job, %{"status" => "succeeded", "structured_output" => @output})

    assert render(view) =~ "Phoenix"
    assert has_element?(view, "[data-testid=proposal-analysis] strong", "Phoenix")
    assert has_element?(view, "[data-testid=proposal-checks]", "mix credo")
    assert has_element?(view, "[data-testid=proposal-checks]", "2 avisos")
    assert has_element?(view, "[data-testid=proposal-stage-1]", "{{projeto.teste}}")
    assert has_element?(view, "[data-testid=proposal-regenerate]")
    assert has_element?(index, "[data-testid=proposal-status-#{job.id}]", "Pronta")
  end

  test "saves the project and opens the pipeline form filled with the proposal", ctx do
    job = finish(ctx, proposal(ctx), %{"status" => "succeeded", "structured_output" => @output})

    {:ok, view, _html} =
      live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/pipelines/proposals/#{job.id}")

    {:error, {:live_redirect, %{to: path}}} =
      view
      |> form("#proposal-project-form", project: %{lint_command: "mix credo"})
      |> render_submit()

    assert path == ~p"/w/#{ctx.workspace.slug}/pipelines/new?proposta=#{job.id}"
    project = Projects.for_directory(ctx.workspace, "app")
    assert project.name == "App"
    assert project.test_command == "mix test"
    assert project.lint_command == "mix credo"
    assert project.copy_paths == ["deps"]

    {:ok, form, _html} = live(ctx.conn, path)
    assert has_element?(form, "[data-testid=pipeline-from-proposal]")
    assert form |> element("[data-testid=pipeline-name]") |> render() =~ "Entrega do App"
    assert form |> element("[data-testid=stage-gates-1]") |> render() =~ "{{projeto.teste}}"

    {:error, {:live_redirect, _}} =
      form |> form("#pipeline-form") |> render_submit()

    assert [%{name: "Entrega do App", delivery: "pr", stages: [_, %{max_attempts: 3}]}] =
             Pipelines.list_pipelines(ctx.workspace)

    # The directory's project is updated by the next proposal, not duplicated.
    again = finish(ctx, proposal(ctx), %{"status" => "succeeded", "structured_output" => @output})

    {:ok, view, _html} =
      live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/pipelines/proposals/#{again.id}")

    assert render(view) =~ "atualiza o existente"
  end

  test "a failed proposal says why and can run again with a comment", ctx do
    job = finish(ctx, proposal(ctx), %{"status" => "failed", "error" => "sem créditos"})

    {:ok, view, _html} =
      live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/pipelines/proposals/#{job.id}")

    assert has_element?(view, "[data-testid=proposal-error]", "sem créditos")

    view |> element("[data-testid=proposal-regenerate]") |> render_click()

    {:error, {:live_redirect, %{to: path}}} =
      view |> form("#feedback-form", round: %{feedback: "Só duas etapas"}) |> render_submit()

    next = Enum.find(Proposals.list_recent(ctx.workspace), &(&1.id != job.id))
    assert path == ~p"/w/#{ctx.workspace.slug}/pipelines/proposals/#{next.id}"
    assert next.prompt =~ "Só duas etapas"
  end

  test "a pipeline form named after a missing proposal starts empty", ctx do
    job = finish(ctx, proposal(ctx), %{"status" => "failed", "error" => "x"})

    {:ok, form, _html} =
      live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/pipelines/new?proposta=#{job.id}")

    refute form |> element("[data-testid=pipeline-name]") |> render() =~ "Entrega"

    {:ok, form, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/pipelines/new?proposta=nada")
    assert has_element?(form, "[data-testid=pipeline-name]")
  end
end
