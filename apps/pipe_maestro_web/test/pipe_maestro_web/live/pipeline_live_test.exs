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
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/pipelines/new?view=form")

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

    [pipeline] = Pipelines.list_pipelines(workspace)
    assert path == "/w/#{workspace.slug}/pipelines/#{pipeline.id}"
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

    {:ok, view, _html} =
      live(conn, ~p"/w/#{workspace.slug}/pipelines/#{pipeline.id}/edit?view=form")

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
      {:ok, view, _html} =
        live(conn, ~p"/w/#{workspace.slug}/pipelines/#{pipeline.id}/edit?view=form")

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
      assert meta =~ "Sem limite de custo"
      assert meta =~ "2 etapas"
    end

    test "the list previews each pipeline as a small diagram", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/pipelines")

      assert has_element?(
               view,
               "[data-testid=pipeline-preview-Editor] [data-testid=diagram-stage-0]"
             )

      refute has_element?(view, "[data-testid=pipeline-Editor] [data-testid=diagram-rail]")
      refute has_element?(view, "[data-testid=pipeline-Editor] [phx-click=select_node]")
    end

    test "the form says an empty cost cap is no limit", %{conn: conn, workspace: workspace} do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/pipelines/new")
      html = render(view)

      assert html =~ "Teto de custo por tarefa (US$, opcional)"
      assert html =~ "Vazio é sem limite. Com um valor, a tarefa para e pede uma decisão"
      assert html =~ "Um teto de custo, se quiser, e o que vira do código."
      assert html =~ "Teto de custo (US$, opcional)"
      refute html =~ "Orçamento"
    end
  end

  describe "the pipeline page" do
    setup %{workspace: workspace} do
      pipeline =
        pipeline_fixture(workspace, %{
          "name" => "Bug",
          "delivery" => "pr",
          "stages" => [
            %{"key" => "a", "name" => "Etapa A", "prompt" => "Faça **A**"},
            %{
              "key" => "b",
              "name" => "Etapa B",
              "prompt" => "Faça B",
              "gates_text" => "mix test",
              "rules_text" => "risco == alto"
            }
          ]
        })

      %{pipeline: pipeline}
    end

    test "shows the pipeline as a diagram", %{
      conn: conn,
      workspace: workspace,
      pipeline: pipeline
    } do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/pipelines/#{pipeline.id}")

      assert has_element?(view, "[data-testid=pipeline-diagram]")
      assert has_element?(view, "[data-testid=diagram-stage-0]", "Etapa A")
      assert has_element?(view, "[data-testid=diagram-edge-1-rule-0]", "risco == alto")
      assert has_element?(view, "[data-testid=diagram-delivery]", "Pull request")
      assert has_element?(view, "[data-testid=pipeline-page-version]", "v1")
    end

    test "a stage opens in the side panel, and closes", %{
      conn: conn,
      workspace: workspace,
      pipeline: pipeline
    } do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/pipelines/#{pipeline.id}")
      refute has_element?(view, "[data-testid=pipeline-panel]")

      view |> element("[data-testid=diagram-select-1]") |> render_click()
      assert has_element?(view, "[data-testid=pipeline-panel]", "Etapa B")
      assert has_element?(view, "[data-testid=stage-details-gates]", "mix test")
      assert has_element?(view, "[data-testid=diagram-select-1][aria-pressed=true]")

      view |> element("[data-testid=pipeline-panel-close]") |> render_click()
      refute has_element?(view, "[data-testid=pipeline-panel]")

      view |> element("[data-testid=diagram-entry]") |> render_click()
      assert has_element?(view, "[data-testid=pipeline-summary-delivery]", "Pull request")
    end

    test "an admin can edit it from there", %{
      conn: conn,
      workspace: workspace,
      pipeline: pipeline
    } do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/pipelines/#{pipeline.id}")

      assert has_element?(
               view,
               ~s([data-testid=pipeline-page-edit][href="/w/#{workspace.slug}/pipelines/#{pipeline.id}/edit"])
             )
    end

    test "a pipeline of another workspace is not found", %{conn: conn, workspace: workspace} do
      other = pipeline_fixture(workspace_fixture(%{name: "Outro"}))

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/w/#{workspace.slug}/pipelines/#{other.id}")
      end
    end

    test "the list leads to it", %{conn: conn, workspace: workspace, pipeline: pipeline} do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/pipelines")

      assert has_element?(
               view,
               ~s([data-testid=pipeline-open-Bug][href="/w/#{workspace.slug}/pipelines/#{pipeline.id}"])
             )
    end

    test "saving an edit leads back to it", %{
      conn: conn,
      workspace: workspace,
      pipeline: pipeline
    } do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/pipelines/#{pipeline.id}/edit")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> form("#pipeline-form", pipeline: %{description: "x"}) |> render_submit()

      assert to == "/w/#{workspace.slug}/pipelines/#{pipeline.id}"
    end
  end

  describe "the editor's diagram" do
    setup %{workspace: workspace} do
      %{pipeline: pipeline_fixture(workspace, %{"name" => "Meu"})}
    end

    defp edit(conn, workspace, pipeline, query \\ ""),
      do: live(conn, "/w/#{workspace.slug}/pipelines/#{pipeline.id}/edit" <> query)

    test "opens on the diagram, and the form is a tab away", ctx do
      {:ok, view, _html} = edit(ctx.conn, ctx.workspace, ctx.pipeline)

      assert has_element?(view, "[data-testid=pipeline-view-diagram][aria-current]")
      assert has_element?(view, "[data-testid=pipeline-diagram]")
      assert has_element?(view, "[data-testid=diagram-insert-0]")
      refute has_element?(view, "[data-testid=stage-card-0]")

      view |> element("[data-testid=pipeline-view-form]") |> render_click()
      assert_patch(view, "/w/#{ctx.workspace.slug}/pipelines/#{ctx.pipeline.id}/edit?view=form")
      assert has_element?(view, "[data-testid=stage-card-0]")
      refute has_element?(view, "[data-testid=pipeline-diagram]")
    end

    test "every input is in the form once, whichever the tab", ctx do
      for query <- ["", "?view=form"] do
        {:ok, _view, html} = edit(ctx.conn, ctx.workspace, ctx.pipeline, query)

        assert html |> String.split(~s(name="pipeline[stages][1][name]")) |> length() == 2
        assert html |> String.split(~s(name="pipeline[name]")) |> length() == 2
      end
    end

    test "a stage opens in the side panel, editable, and the node follows the draft", ctx do
      {:ok, view, _html} = edit(ctx.conn, ctx.workspace, ctx.pipeline)
      assert has_element?(view, "[data-testid=stage-panel-1].hidden")

      view |> element("[data-testid=diagram-select-1]") |> render_click()
      refute has_element?(view, "[data-testid=stage-panel-1].hidden")
      assert has_element?(view, "[data-testid=stage-panel-0].hidden")

      view
      |> form("#pipeline-form", pipeline: %{stages: %{"1" => %{name: "Revisar"}}})
      |> render_change()

      assert has_element?(view, "[data-testid=diagram-stage-1]", "Revisar")

      view |> element("[data-testid=stage-panel-1-close]") |> render_click()
      assert has_element?(view, "[data-testid=stage-panel-1].hidden")
    end

    test "the entry opens the pipeline's own settings", ctx do
      {:ok, view, _html} = edit(ctx.conn, ctx.workspace, ctx.pipeline)
      assert has_element?(view, "[data-testid=pipeline-panel].hidden")

      view |> element("[data-testid=diagram-entry]") |> render_click()
      refute has_element?(view, "[data-testid=pipeline-panel].hidden")
      assert has_element?(view, "[data-testid=pipeline-panel] [data-testid=pipeline-name]")
    end

    test "saves from the diagram", ctx do
      {:ok, view, _html} = edit(ctx.conn, ctx.workspace, ctx.pipeline)
      view |> element("[data-testid=diagram-select-0]") |> render_click()

      {:error, {:live_redirect, _}} =
        view
        |> form("#pipeline-form", pipeline: %{stages: %{"0" => %{name: "Primeira"}}})
        |> render_submit()

      assert [%{name: "Primeira"}, %{name: "Etapa B"}] =
               Pipelines.get_pipeline!(ctx.workspace, ctx.pipeline.id).stages
    end

    test "a new pipeline opens on the diagram with its settings open", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/pipelines/new")

      assert has_element?(view, "[data-testid=pipeline-diagram]")
      refute has_element?(view, "[data-testid=pipeline-panel].hidden")
    end
  end

  describe "changing the structure on the diagram" do
    setup %{conn: conn, workspace: workspace} do
      pipeline =
        pipeline_fixture(workspace, %{
          "name" => "Três",
          "stages" => [
            %{"key" => "a", "name" => "A", "prompt" => "a"},
            %{"key" => "b", "name" => "B", "prompt" => "b"},
            %{"key" => "c", "name" => "C", "prompt" => "c"}
          ]
        })

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/pipelines/#{pipeline.id}/edit")
      %{pipeline: pipeline, view: view}
    end

    defp node_names(view) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-testid^=diagram-select-] .truncate")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
    end

    defp click(view, testid), do: view |> element("[data-testid=#{testid}]") |> render_click()

    test "inserts a stage between two and opens it", %{view: view} do
      click(view, "diagram-insert-2")

      assert node_names(view) == ["A", "B", "Nova etapa", "C"]
      refute has_element?(view, "[data-testid=stage-panel-2].hidden")
    end

    test "moves a stage, and its panel follows it", %{view: view} do
      click(view, "diagram-select-0")
      click(view, "diagram-right-0")

      assert node_names(view) == ["B", "A", "C"]
      refute has_element?(view, "[data-testid=stage-panel-1].hidden")
    end

    test "removes a stage", %{view: view} do
      click(view, "diagram-remove-1")
      assert node_names(view) == ["A", "C"]
    end

    test "runs a stage at once with the one before, and back", %{view: view} do
      click(view, "diagram-join-group-2")
      assert has_element?(view, "[data-testid=diagram-step-1][data-parallel]")
      assert has_element?(view, "[data-testid=diagram-fork-1]")

      click(view, "diagram-leave-group-2")
      refute has_element?(view, "[data-parallel]")
    end

    test "the structure saves", %{view: view, workspace: workspace, pipeline: pipeline} do
      click(view, "diagram-join-group-2")
      view |> form("#pipeline-form") |> render_submit()

      assert [%{group: nil}, %{group: "paralelo-1"}, %{group: "paralelo-1"}] =
               Pipelines.get_pipeline!(workspace, pipeline.id).stages
    end
  end
end
