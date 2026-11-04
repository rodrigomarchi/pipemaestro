defmodule PipeMaestroWeb.DecisionsLiveTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.{Jobs, Tasks}

  setup :register_and_log_in_member

  setup %{workspace: workspace, user: user} do
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})
    runner = with_directories(runner, [%{"name" => "app", "git" => true}])
    %{runner: runner, pipeline: pipeline_fixture(workspace, %{"name" => "Duas etapas"})}
  end

  defp blocked_task(ctx, title) do
    {:ok, task} =
      Tasks.create_task(ctx.user, ctx.workspace, %{
        "title" => title,
        "prompt" => "faça",
        "pipeline_id" => ctx.pipeline.id,
        "runner_id" => ctx.runner.id,
        "directory" => "app"
      })

    job = List.last(Tasks.get_task!(ctx.workspace, task.id).stage_runs).job
    {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

    {:ok, _} =
      Jobs.finish_job(ctx.runner, job.id, %{
        "status" => "succeeded",
        "exit_code" => 0,
        "structured_output" => %{"status" => "bloqueado", "resumo" => "Qual navegador?"}
      })

    Tasks.get_task!(ctx.workspace, task.id)
  end

  test "the menu counts the decisions waiting, live, on any page", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/runners")
    refute has_element?(view, "[data-testid=sidebar-decisions]", "1")

    blocked_task(ctx, "Tela branca")
    assert has_element?(view, "[data-testid=sidebar-decisions]", "1")
  end

  test "any page tells, with a toast and a browser notification, when a task pauses", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/runners")

    task = blocked_task(ctx, "Tela branca")
    path = "/w/#{ctx.workspace.slug}/tasks/#{task.id}"

    assert_push_event(view, "notify", %{title: "Tela branca aguarda decisão", url: ^path})
    assert render(view) =~ "Tela branca aguarda decisão"
  end

  test "lists what waits for a decision and decides from there", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/decisions")
    assert has_element?(view, "[data-testid=no-decisions]")

    task = blocked_task(ctx, "Tela branca")
    other = blocked_task(ctx, "Login lento")

    assert has_element?(view, "[data-testid=decision-#{task.id}]", "Tela branca")
    assert has_element?(view, "[data-testid=decision-#{task.id}]", "Qual navegador?")
    assert has_element?(view, "[data-testid=decision-#{task.id}]", "Etapa A")

    view
    |> form("[data-testid=decision-form-#{task.id}]", decision: %{instructions: "Safari 17"})
    |> render_submit(%{"action" => "retry"})

    refute has_element?(view, "[data-testid=decision-#{task.id}]")

    assert List.last(Tasks.get_task!(ctx.workspace, task.id).stage_runs).instructions ==
             "Safari 17"

    view
    |> form("[data-testid=decision-form-#{other.id}]")
    |> render_submit(%{"action" => "cancel"})

    assert Tasks.get_task!(ctx.workspace, other.id).status == :canceled
    assert has_element?(view, "[data-testid=no-decisions]")
  end

  test "each task's questionnaire is answered from the list", ctx do
    task = blocked_task(ctx, "Tela branca")
    other = blocked_task(ctx, "Login lento")
    asked = questions_task(ctx, "Menu quebrado")

    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/decisions")

    assert has_element?(view, "[data-testid=questionnaire-#{asked.id}]")

    assert has_element?(
             view,
             "[data-testid=question-0-#{asked.id}]",
             "Em qual navegador reproduz?"
           )

    assert has_element?(view, "[data-testid=question-0-option-0-#{asked.id}]", "Safari 17")
    assert has_element?(view, "[data-testid=question-0-other-#{asked.id}]")
    assert has_element?(view, "[data-testid=questionnaire-submit-#{asked.id}][disabled]")
    # A block with nothing to ask has the manual decision, whatever the analysis does.
    assert has_element?(view, "[data-testid=decision-form-#{task.id}]")
    assert has_element?(view, "[data-testid=decision-form-#{other.id}]")

    view
    |> element("[data-testid=questionnaire-form-#{asked.id}]")
    |> render_change(%{"answers" => %{"0" => %{"escolhas" => [], "outro" => "No Firefox"}}})

    refute has_element?(view, "[data-testid=questionnaire-submit-#{asked.id}][disabled]")

    view |> element("[data-testid=questionnaire-form-#{asked.id}]") |> render_submit()
    assert has_element?(view, "[data-testid=questionnaire-review-#{asked.id}]", "No Firefox")
    view |> element("[data-testid=questionnaire-confirm-#{asked.id}]") |> render_click()

    refute has_element?(view, "[data-testid=decision-#{asked.id}]")
    assert has_element?(view, "[data-testid=decision-#{task.id}]")

    run = List.last(Tasks.get_task!(ctx.workspace, asked.id).stage_runs)
    assert %{"respostas" => [%{"escolhas" => [], "outro" => "No Firefox"}]} = run.answers
  end

  defp questions_task(ctx, title) do
    {:ok, task} =
      Tasks.create_task(ctx.user, ctx.workspace, %{
        "title" => title,
        "prompt" => "faça",
        "pipeline_id" => ctx.pipeline.id,
        "runner_id" => ctx.runner.id,
        "directory" => "app"
      })

    job = List.last(Tasks.get_task!(ctx.workspace, task.id).stage_runs).job
    {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

    {:ok, _} =
      Jobs.finish_job(ctx.runner, job.id, %{
        "status" => "succeeded",
        "exit_code" => 0,
        "structured_output" => %{
          "status" => "bloqueado",
          "resumo" => "Uma dúvida",
          "perguntas" => [
            %{
              "titulo" => "Navegador",
              "pergunta" => "Em qual navegador reproduz?",
              "multipla" => false,
              "opcoes" => [
                %{"rotulo" => "Chrome", "descricao" => "", "recomendada" => false},
                %{"rotulo" => "Safari 17", "descricao" => "", "recomendada" => true}
              ]
            }
          ]
        }
      })

    Tasks.get_task!(ctx.workspace, task.id)
  end

  test "shows who decides and by when, passes it on, and filters mine", ctx do
    task = blocked_task(ctx, "Tela branca")
    colleague = member_fixture(ctx.workspace, %{name: "Bia"})

    {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/decisions")

    assert has_element?(
             view,
             "[data-testid=decision-owner-#{task.id}] option[selected]",
             ctx.user.name
           )

    assert has_element?(view, "[data-testid=decision-due-#{task.id}]", "em ")

    view
    |> form("[data-testid=decision-owner-form-#{task.id}]", owner: %{user_id: colleague.id})
    |> render_change()

    assert Tasks.get_task!(ctx.workspace, task.id).decision_owner_id == colleague.id

    view |> element("[data-testid=decisions-mine]") |> render_click()
    refute has_element?(view, "[data-testid=decision-#{task.id}]")
    view |> element("[data-testid=decisions-all]") |> render_click()
    assert has_element?(view, "[data-testid=decision-#{task.id}]")
  end
end
