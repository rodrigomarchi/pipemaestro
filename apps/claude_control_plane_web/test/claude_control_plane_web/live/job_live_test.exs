defmodule ClaudeControlPlaneWeb.JobLiveTest do
  use ClaudeControlPlaneWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ClaudeControlPlane.Jobs

  setup :register_and_log_in_member

  setup %{workspace: workspace, user: user} do
    {runner, _token} = runner_fixture(workspace, user, %{name: "build-01"})
    %{runner: runner, job: job_fixture(runner, user, %{"prompt" => "crie um hello.txt"})}
  end

  defp event(seq, type, data), do: %{"seq" => seq, "type" => type, "data" => data}

  test "shows the run growing live until it ends", %{
    conn: conn,
    workspace: workspace,
    runner: runner,
    job: job
  } do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/jobs/#{job.id}")

    assert has_element?(view, "[data-testid=job-prompt-text]", "crie um hello.txt")
    assert has_element?(view, "[data-testid=job-status]", "Na fila")
    assert has_element?(view, "[data-testid=job-no-events]", "Aguardando")
    assert has_element?(view, "[data-testid=job-runner-name]", "build-01")

    {:ok, _} = Jobs.mark_started(runner, job.id)

    {:ok, _} =
      Jobs.append_event(runner, job.id, event(1, "system", %{"text" => "Sessão iniciada"}))

    {:ok, _} =
      Jobs.append_event(
        runner,
        job.id,
        event(2, "tool_use", %{"name" => "Write", "text" => "hello.txt"})
      )

    {:ok, _} =
      Jobs.append_event(
        runner,
        job.id,
        event(3, "tool_result", %{"text" => "ops", "is_error" => true})
      )

    {:ok, _} = Jobs.append_event(runner, job.id, event(4, "assistant_text", %{"text" => "feito"}))
    {:ok, _} = Jobs.append_event(runner, job.id, event(5, "result", %{"text" => "feito"}))

    assert has_element?(view, "[data-testid=job-status]", "Executando")
    assert has_element?(view, "[data-testid=job-event-count]", "5 eventos")
    assert has_element?(view, "[data-testid=job-event][data-type=tool_use]", "Write")

    assert has_element?(
             view,
             "[data-testid=job-event][data-type=tool_result]",
             "Erro da ferramenta"
           )

    assert has_element?(view, "[data-testid=job-event][data-type=assistant_text]", "feito")

    refute has_element?(view, "[data-testid=job-typing]")
    Jobs.relay_delta(runner, job.id, "Estou olhando o **login**")
    assert has_element?(view, "[data-testid=job-typing]", "Estou olhando o")

    {:ok, _} =
      Jobs.append_event(runner, job.id, %{
        "seq" => 99,
        "type" => "assistant_text",
        "data" => %{"text" => "Estou olhando o login."}
      })

    refute has_element?(view, "[data-testid=job-typing]")

    {:ok, _} =
      Jobs.finish_job(runner, job.id, %{
        "status" => "succeeded",
        "result" => "**feito**, sem pendências",
        "exit_code" => 0,
        "num_turns" => 3,
        "duration_ms" => 850
      })

    assert has_element?(view, "[data-testid=job-status]", "Concluído")
    assert has_element?(view, "[data-testid=job-result] strong", "feito")
    assert has_element?(view, "[data-testid=job-duration]", "850 ms")
    refute has_element?(view, "[data-testid=job-cancel]")
  end

  test "cancels a queued job", %{conn: conn, workspace: workspace, runner: runner, job: job} do
    Jobs.subscribe({:runner, runner.id})
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/jobs/#{job.id}")

    view |> element("[data-testid=job-cancel]") |> render_click()

    assert_receive {:job_cancel, _id}
    assert has_element?(view, "[data-testid=job-status]", "Cancelado")
    refute has_element?(view, "[data-testid=job-cancel]")
  end

  test "a running job shows it is being canceled; a failure shows its error", %{
    conn: conn,
    workspace: workspace,
    runner: runner,
    job: job
  } do
    {:ok, _} = Jobs.mark_started(runner, job.id)
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/jobs/#{job.id}")

    view |> element("[data-testid=job-cancel]") |> render_click()
    assert has_element?(view, "[data-testid=job-status]", "Cancelando")

    {:ok, _} =
      Jobs.finish_job(runner, job.id, %{"status" => "failed", "error" => "claude saiu com 1"})

    assert has_element?(view, "[data-testid=job-status]", "Falhou")
    assert has_element?(view, "[data-testid=job-error]", "claude saiu com 1")

    assert render_click(view, "cancel") =~ "A execução já terminou"
  end

  test "another workspace's job is not found, even for a member of both", %{
    conn: conn,
    user: user,
    job: job
  } do
    other = workspace_fixture()
    {:ok, _membership} = ClaudeControlPlane.Workspaces.add_member(other, user)

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/w/#{other.slug}/jobs/#{job.id}")
    end
  end
end
