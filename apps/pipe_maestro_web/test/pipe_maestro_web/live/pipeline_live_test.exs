defmodule PipeMaestroWeb.PipelineLiveTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.Pipelines

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

  test "exports a pipeline as YAML and imports one", %{conn: conn, workspace: workspace} do
    pipeline_fixture(workspace, %{"name" => "Meu"})
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/pipelines")

    view |> element("[data-testid=pipeline-export-Meu]") |> render_click()
    yaml = view |> element("[data-testid=pipeline-yaml]") |> render()
    assert yaml =~ "name: &quot;Meu&quot;"
    assert has_element?(view, "[data-testid=pipeline-yaml-download][download='meu.yaml']")
    render_click(view, "close_yaml")

    view |> element("[data-testid=import-pipeline]") |> render_click()

    html =
      view |> form("#import-form", import: %{yaml: "name: [quebrado"}) |> render_submit()

    assert html =~ "YAML inválido"

    copy =
      String.replace(
        Pipelines.export_yaml(Pipelines.list_pipelines(workspace) |> hd()),
        "Meu",
        "Cópia"
      )

    view |> form("#import-form", import: %{yaml: copy}) |> render_submit()
    assert has_element?(view, "[data-testid='pipeline-Cópia']")
    refute has_element?(view, "#import-form")
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
        "system_prompt" => "Nunca altere código.",
        "max_task_cost_usd" => "2.5",
        "delivery" => "commit",
        "mcp_config_json" => ~s({"mcpServers": {"grafana": {"command": "mcp-grafana"}}}),
        "stages" => [
          %{
            "name" => "Corrigir",
            "prompt" => "p",
            "timeout_minutes" => 15,
            "gates_text" => "{{projeto.teste}}\n! mix test test/repro_test.exs",
            "rules_text" => "risco == alto",
            "agent" => "analista"
          }
        ]
      })

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/pipelines/#{pipeline.id}/edit")

    assert view |> element("[data-testid=stage-gates-0]") |> render() =~
             "! mix test test/repro_test.exs"

    assert view |> element("[data-testid=stage-rules-0]") |> render() =~ "risco == alto"
    # Every stage runs with every permission and passes on by itself.
    for gone <- ~w(stage-permission-0 stage-allowed-0 stage-denied-0 stage-pause-0),
        do: refute(has_element?(view, "[data-testid=#{gone}]"))

    assert view |> element("[data-testid=pipeline-mcp-config]") |> render() =~ "grafana"
    assert has_element?(view, "[data-testid=stage-agent-0][value=analista]")
    assert has_element?(view, "[data-testid=stage-group-0]")

    {:error, {:live_redirect, _}} =
      view
      |> form("#pipeline-form", pipeline: %{stages: %{"0" => %{rules_text: "risco != baixo"}}})
      |> render_submit()

    [stage] = Pipelines.get_pipeline!(workspace, pipeline.id).stages
    assert stage.timeout_minutes == 15
    assert [%{"expect" => "pass"}, %{"expect" => "fail"}] = stage.gates
    assert stage.rules == [%{"field" => "risco", "op" => "!=", "value" => "baixo"}]
    assert stage.agent == "analista"
    pipeline = Pipelines.get_pipeline!(workspace, pipeline.id)
    assert pipeline.system_prompt == "Nunca altere código."
    assert Decimal.equal?(pipeline.max_task_cost_usd, Decimal.new("2.5"))
    assert pipeline.delivery == "commit"
    assert %{"mcpServers" => %{"grafana" => _}} = pipeline.mcp_config
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

  describe "the prompt editor" do
    setup %{workspace: workspace} do
      pipeline =
        pipeline_fixture(workspace, %{
          "name" => "Editor",
          "delivery" => "pr",
          "stages" => [
            %{
              "name" => "Plano",
              "prompt" => "## Objetivo\n\nFaça **isto** com {{tarefa.descricao}}",
              "gates_text" => "mix test"
            },
            %{"name" => "Revisão", "prompt" => "Revise", "group" => "revisoes"}
          ]
        })

      %{pipeline: pipeline}
    end

    test "has a toolbar and a menu of the prompt variables", %{
      conn: conn,
      workspace: workspace,
      pipeline: pipeline
    } do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/pipelines/#{pipeline.id}/edit")

      for action <- ~w(bold italic heading bullet numbered quote code link),
          do:
            assert(
              has_element?(
                view,
                "[data-testid=stage-prompt-0-#{action}][data-md-action=#{action}]"
              )
            )

      assert has_element?(
               view,
               "[data-testid='stage-prompt-0-variable-tarefa.descricao'][data-md-insert='{{tarefa.descricao}}']"
             )

      assert has_element?(view, "#stage-0-prompt[phx-hook=MarkdownEditor]")
      assert has_element?(view, "[data-testid=pipeline-system-prompt-editor]")
    end

    test "previews the prompt as Markdown, keeping the textarea in the form", %{
      conn: conn,
      workspace: workspace,
      pipeline: pipeline
    } do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/pipelines/#{pipeline.id}/edit")
      refute has_element?(view, "[data-testid=stage-prompt-0-preview]")

      view |> element("[data-testid=stage-prompt-0-preview-tab]") |> render_click()

      preview = view |> element("[data-testid=stage-prompt-0-preview]") |> render()
      assert preview =~ "<h2>Objetivo</h2>"
      assert preview =~ "<strong>isto</strong>"
      assert has_element?(view, "[data-testid=stage-prompt-0]")

      # What is typed shows in the preview.
      view
      |> form("#pipeline-form", pipeline: %{stages: %{"0" => %{prompt: "_novo_"}}})
      |> render_change()

      assert view |> element("[data-testid=stage-prompt-0-preview]") |> render() =~
               "<em>novo</em>"

      view |> element("[data-testid=stage-prompt-0-write-tab]") |> render_click()
      refute has_element?(view, "[data-testid=stage-prompt-0-preview]")
    end

    test "a stage collapses to its summary and the delivery explains itself", %{
      conn: conn,
      workspace: workspace,
      pipeline: pipeline
    } do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/pipelines/#{pipeline.id}/edit")

      assert view |> element("[data-testid=stage-chips-0]") |> render() =~ "1 gate"
      assert view |> element("[data-testid=stage-chips-1]") |> render() =~ "grupo revisoes"
      assert view |> element("[data-testid=pipeline-delivery-help]") |> render() =~ "PR"

      view |> element("[data-testid=stage-toggle-0]") |> render_click()
      assert has_element?(view, "[data-testid=stage-body-0].hidden")
      # The collapsed stage's inputs stay in the form.
      assert has_element?(view, "[data-testid=stage-prompt-0]")

      view |> element("[data-testid=stage-toggle-0]") |> render_click()
      refute has_element?(view, "[data-testid=stage-body-0].hidden")
    end

    test "the list shows each pipeline's delivery, budget and stages", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/pipelines")
      meta = view |> element("[data-testid=pipeline-meta-Editor]") |> render()
      assert meta =~ "Pull request"
      assert meta =~ "Sem teto"
      assert meta =~ "2 etapas"
    end
  end
end
