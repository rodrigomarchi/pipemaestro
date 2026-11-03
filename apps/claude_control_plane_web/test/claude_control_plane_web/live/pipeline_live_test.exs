defmodule ClaudeControlPlaneWeb.PipelineLiveTest do
  use ClaudeControlPlaneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ClaudeControlPlane.Pipelines

  setup :register_and_log_in_member

  test "an empty workspace creates the ready-made pipelines", %{conn: conn, workspace: workspace} do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/pipelines")
    assert has_element?(view, "[data-testid=no-pipelines]")

    view |> element("[data-testid=create-default-pipelines]") |> render_click()

    assert has_element?(view, "[data-testid='pipeline-Correção de bug']", "Investigação")
    assert has_element?(view, "[data-testid='pipeline-version-Prompt único']", "v1")
  end

  test "creates a pipeline, adding, moving and removing stages", %{
    conn: conn,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/pipelines/new")

    view
    |> form("#pipeline-form",
      pipeline: %{
        name: "Revisão",
        stages: %{
          "0" => %{name: "Ler", prompt: "Leia {{tarefa.descricao}}", timeout_minutes: "20"}
        }
      }
    )
    |> render_change()

    assert has_element?(view, "[data-testid=stage-timeout-0][value=\"20\"]")

    view |> element("[data-testid=stage-add]") |> render_click()
    view |> element("[data-testid=stage-add]") |> render_click()

    view
    |> form("#pipeline-form",
      pipeline: %{
        stages: %{
          "1" => %{name: "Escrever", prompt: "Escreva"},
          "2" => %{name: "Descartável", prompt: "x"}
        }
      }
    )
    |> render_change()

    view |> element("[data-testid=stage-remove-2]") |> render_click()
    view |> element("[data-testid=stage-up-1]") |> render_click()

    {:error, {:live_redirect, %{to: path}}} =
      view |> form("#pipeline-form") |> render_submit()

    assert path == "/w/#{workspace.slug}/pipelines"

    [pipeline] = Pipelines.list_pipelines(workspace)
    assert pipeline.name == "Revisão"
    assert Enum.map(pipeline.stages, & &1.key) == ["escrever", "ler"]
    assert Enum.map(pipeline.stages, & &1.timeout_minutes) == [60, 20]
  end

  test "shows the errors of an invalid stage", %{conn: conn, workspace: workspace} do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/pipelines/new")

    html =
      view
      |> form("#pipeline-form",
        pipeline: %{
          name: "Ruim",
          stages: %{"0" => %{name: "Etapa", prompt: "{{nao.existe}}", output_schema_json: "{x"}}
        }
      )
      |> render_submit()

    assert html =~ "variáveis desconhecidas: nao.existe"
    assert html =~ "JSON inválido"
    assert Pipelines.list_pipelines(workspace) == []
  end

  test "editing keeps every stage setting and edits gates and rules", %{
    conn: conn,
    workspace: workspace
  } do
    pipeline =
      pipeline_fixture(workspace, %{
        "name" => "Completo",
        "stages" => [
          %{
            "name" => "Corrigir",
            "prompt" => "p",
            "timeout_minutes" => 15,
            "gates_text" => "{{projeto.teste}}\n! mix test test/repro_test.exs",
            "rules_text" => "risco == alto"
          }
        ]
      })

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/pipelines/#{pipeline.id}/edit")

    assert view |> element("[data-testid=stage-gates-0]") |> render() =~
             "! mix test test/repro_test.exs"

    assert view |> element("[data-testid=stage-rules-0]") |> render() =~ "risco == alto"

    {:error, {:live_redirect, _}} =
      view
      |> form("#pipeline-form", pipeline: %{stages: %{"0" => %{rules_text: "risco != baixo"}}})
      |> render_submit()

    [stage] = Pipelines.get_pipeline!(workspace, pipeline.id).stages
    assert stage.timeout_minutes == 15
    assert [%{"expect" => "pass"}, %{"expect" => "fail"}] = stage.gates
    assert stage.rules == [%{"field" => "risco", "op" => "!=", "value" => "baixo"}]
  end

  test "edits a pipeline, bumping its version, and deletes it", %{
    conn: conn,
    workspace: workspace
  } do
    pipeline = pipeline_fixture(workspace, %{"name" => "Meu"})

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/pipelines/#{pipeline.id}/edit")
    assert has_element?(view, "[data-testid=stage-name-1]")

    view |> element("[data-testid=stage-down-0]") |> render_click()

    {:error, {:live_redirect, _}} =
      view
      |> form("#pipeline-form", pipeline: %{description: "editado"})
      |> render_submit()

    pipeline = Pipelines.get_pipeline!(workspace, pipeline.id)
    assert pipeline.version == 2
    assert Enum.map(pipeline.stages, & &1.key) == ["b", "a"]

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/pipelines")
    view |> element("[data-testid=pipeline-delete-Meu]") |> render_click()
    refute has_element?(view, "[data-testid=pipeline-Meu]")
  end
end
