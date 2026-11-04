defmodule PipeMaestro.PipelinesTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.Pipelines
  alias PipeMaestro.Pipelines.{Pipeline, Prompt, Stage, Templates}

  setup do
    %{workspace: workspace_fixture()}
  end

  describe "pipelines" do
    test "create, list, update bumps the version, delete", %{workspace: workspace} do
      pipeline = pipeline_fixture(workspace, %{"name" => "Meu pipeline"})
      assert pipeline.version == 1
      assert [%Stage{key: "a", max_attempts: 2}, %Stage{key: "b"}] = pipeline.stages
      assert [%Pipeline{name: "Meu pipeline"}] = Pipelines.list_pipelines(workspace)

      {:ok, updated} = Pipelines.update_pipeline(pipeline, %{"description" => "novo"})
      assert updated.version == 2
      assert Pipelines.get_pipeline!(workspace, pipeline.id).description == "novo"

      {:ok, _} = Pipelines.delete_pipeline(updated)
      assert Pipelines.list_pipelines(workspace) == []
    end

    test "stages are reordered and dropped through the form params", %{workspace: workspace} do
      pipeline = pipeline_fixture(workspace)

      params = %{
        "stages" => %{
          "0" => %{"key" => "a", "name" => "Etapa A", "prompt" => "A"},
          "1" => %{"key" => "b", "name" => "Etapa B", "prompt" => "B"},
          "2" => %{"key" => "c", "name" => "Etapa C", "prompt" => "C"}
        },
        "stages_sort" => ["2", "0", "1"],
        "stages_drop" => ["1"]
      }

      {:ok, updated} = Pipelines.update_pipeline(pipeline, params)
      assert Enum.map(updated.stages, & &1.key) == ["c", "a"]
    end

    test "validates name, stages, keys, variables, model and schema", %{workspace: workspace} do
      pipeline_fixture(workspace, %{"name" => "Repetido"})

      assert {:error, changeset} =
               Pipelines.create_pipeline(workspace, %{"name" => "Repetido", "stages" => []})

      errors = errors_on(changeset)
      assert errors.name == ["já existe um pipeline com esse nome"]
      assert errors.stages == ["adicione ao menos uma etapa"]

      stage = fn attrs -> Map.merge(%{"name" => "Etapa", "prompt" => "p"}, attrs) end

      assert {:error, changeset} =
               Pipelines.create_pipeline(workspace, %{
                 "name" => "Ruim",
                 "stages" => [
                   stage.(%{"key" => "x"}),
                   stage.(%{"key" => "x"}),
                   stage.(%{"prompt" => "{{nao.existe}}", "model" => "gpt", "max_attempts" => 9}),
                   stage.(%{"output_schema_json" => "{not json"}),
                   stage.(%{"output_schema_json" => ~s({"type": "string"})})
                 ]
               })

      assert {"cada etapa precisa de uma chave própria" <> _, _} = changeset.errors[:stages]

      stage_errors = changeset.changes.stages |> Enum.map(&errors_on/1)
      assert %{prompt: ["variáveis desconhecidas: nao.existe"]} = Enum.at(stage_errors, 2)
      assert %{model: [_], max_attempts: [_]} = Enum.at(stage_errors, 2)
      assert %{output_schema_json: ["JSON inválido"]} = Enum.at(stage_errors, 3)
      assert %{output_schema_json: ["precisa ser" <> _]} = Enum.at(stage_errors, 4)
    end

    test "a stage's key comes from its name and its schema from JSON", %{workspace: workspace} do
      {:ok, pipeline} =
        Pipelines.create_pipeline(workspace, %{
          "name" => "Chaves",
          "stages" => [
            %{
              "name" => "Revisão de Código",
              "prompt" => "p",
              "output_schema_json" =>
                ~s({"type": "object", "properties": {"nota": {"type": "integer"}}, "required": ["nota"]})
            }
          ]
        })

      assert [%Stage{key: "revisao-de-codigo", output_schema: %{"properties" => %{"nota" => _}}}] =
               pipeline.stages
    end

    test "gates and rules come as text, one per line", %{workspace: workspace} do
      {:ok, pipeline} =
        Pipelines.create_pipeline(workspace, %{
          "name" => "Com gates",
          "stages" => [
            %{
              "name" => "Reproduzir",
              "prompt" => "p",
              "gates_text" => "{{projeto.teste}}\n\n! mix test test/repro_test.exs\n",
              "rules_text" => "bem_definida == false\nrisco != baixo"
            }
          ]
        })

      assert [%Stage{gates: gates, rules: rules} = stage] = pipeline.stages

      assert gates == [
               %{"command" => "{{projeto.teste}}", "expect" => "pass"},
               %{"command" => "mix test test/repro_test.exs", "expect" => "fail"}
             ]

      assert rules == [
               %{"field" => "bem_definida", "op" => "==", "value" => "false"},
               %{"field" => "risco", "op" => "!=", "value" => "baixo"}
             ]

      assert Stage.gates_text(stage) == "{{projeto.teste}}\n! mix test test/repro_test.exs"
      assert Stage.rules_text(stage) == "bem_definida == false\nrisco != baixo"

      for {field, text} <- [{"gates_text", "{{nao.existe}}"}, {"rules_text", "sem operador"}] do
        assert {:error, changeset} =
                 Pipelines.create_pipeline(workspace, %{
                   "name" => "Ruim #{field}",
                   "stages" => [%{"name" => "E", "prompt" => "p", field => text}]
                 })

        assert [%{} = errors] = errors_on(changeset).stages
        assert Map.has_key?(errors, String.to_atom(field))
      end
    end

    test "a stage has no permission or approval settings: it runs with every permission and passes on",
         %{workspace: workspace} do
      stage = %{
        "name" => "Ler",
        "prompt" => "p",
        "pause_after" => "true",
        "permission_profile" => "leitura",
        "allowed_tools_text" => "Bash(git log:*)"
      }

      {:ok, pipeline} =
        Pipelines.create_pipeline(workspace, %{"name" => "P", "stages" => [stage]})

      assert [%Stage{} = saved] = pipeline.stages

      for gone <- [:pause_after, :permission_profile, :allowed_tools, :denied_tools],
          do: refute(Map.has_key?(saved, gone))
    end

    test "a pipeline's context: system prompt, MCP servers and agents, from JSON", %{
      workspace: workspace
    } do
      attrs = %{
        "name" => "Investigação",
        "system_prompt" => "Nunca altere código.",
        "mcp_config_json" => ~s({"mcpServers": {"grafana": {"command": "mcp-grafana"}}}),
        "agents_json" => ~s({"analista": {"description": "Lê métricas", "prompt": "Analise."}}),
        "stages" => [%{"name" => "Analisar", "prompt" => "p", "agent" => "analista"}]
      }

      {:ok, pipeline} = Pipelines.create_pipeline(workspace, attrs)
      assert pipeline.system_prompt == "Nunca altere código."
      assert %{"mcpServers" => %{"grafana" => _}} = pipeline.mcp_config
      assert %{"analista" => _} = pipeline.agents
      assert [%Stage{agent: "analista"}] = pipeline.stages
      assert Pipeline.mcp_config_json(pipeline) =~ "grafana"

      for {field, json} <- [
            {"mcp_config_json", ~s({"x": 1})},
            {"agents_json", "[1]"},
            {"mcp_config_json", "{"}
          ] do
        assert {:error, changeset} =
                 Pipelines.create_pipeline(
                   workspace,
                   %{attrs | "name" => "R #{field}#{json}"} |> Map.put(field, json)
                 )

        assert Map.has_key?(errors_on(changeset), String.to_atom(field))
      end
    end

    test "a stage runs for an hour at most unless told otherwise", %{workspace: workspace} do
      stage = %{"name" => "Etapa", "prompt" => "p"}

      {:ok, pipeline} =
        Pipelines.create_pipeline(workspace, %{"name" => "T", "stages" => [stage]})

      assert [%Stage{timeout_minutes: 60}] = pipeline.stages

      {:ok, pipeline} =
        Pipelines.update_pipeline(pipeline, %{
          "stages" => %{"0" => Map.put(stage, "timeout_minutes", "15")}
        })

      assert [%Stage{timeout_minutes: 15}] = pipeline.stages

      for minutes <- ["0", "1441"] do
        assert {:error, changeset} =
                 Pipelines.update_pipeline(pipeline, %{
                   "stages" => %{"0" => Map.put(stage, "timeout_minutes", minutes)}
                 })

        assert %{timeout_minutes: ["use de 1 a 1440 minutos"]} in errors_on(changeset).stages
      end
    end

    test "create_defaults adds the templates once", %{workspace: workspace} do
      created = Pipelines.create_defaults(workspace)
      assert length(created) == length(Templates.all())
      assert Pipelines.create_defaults(workspace) == []

      names = workspace |> Pipelines.list_pipelines() |> Enum.map(& &1.name)
      assert "Correção de bug" in names
      assert "Prompt único" in names
      assert "Investigação de produção" in names

      bug_fix = Enum.find(Pipelines.list_pipelines(workspace), &(&1.name == "Correção de bug"))

      assert Enum.map(bug_fix.stages, & &1.key) ==
               ~w(triagem investigacao reproducao implementacao auditoria pr)

      feature =
        Enum.find(Pipelines.list_pipelines(workspace), &(&1.name == "Nova funcionalidade"))

      assert Enum.map(feature.stages, & &1.group) == [nil, nil, nil, "revisoes", "revisoes"]
    end

    test "exports to YAML and imports it back as the same pipeline", %{workspace: workspace} do
      {:ok, original} =
        Pipelines.create_pipeline(workspace, %{
          "name" => "Completo",
          "description" => "Com tudo: \"aspas\", dois-pontos: e #.",
          "system_prompt" => "Linha 1\nLinha 2",
          "max_task_cost_usd" => "2.5",
          "mcp_config_json" =>
            ~s({"mcpServers": {"grafana": {"command": "mcp-grafana", "args": ["-t"]}}}),
          "agents_json" => ~s({"revisor": {"description": "d", "prompt": "p"}}),
          "stages" => [
            %{
              "key" => "a",
              "name" => "Etapa: A",
              "prompt" => "Faça {{tarefa.descricao}}\n\n- item\n  recuado",
              "max_attempts" => 3,
              "model" => "sonnet",
              "max_budget_usd" => "1.5",
              "timeout_minutes" => 30,
              "agent" => "revisor",
              "group" => nil,
              "gates_text" => "{{projeto.teste}}\n! mix test test/x.exs",
              "rules_text" => "risco == alto",
              "output_schema_json" =>
                ~s({"type": "object", "properties": {"risco": {"type": "string"}}})
            }
          ]
        })

      yaml = Pipelines.export_yaml(original)
      assert yaml =~ "name: \"Completo\""
      assert yaml =~ "prompt: |"

      other = workspace_fixture()
      assert {:ok, imported} = Pipelines.import_yaml(other, yaml)

      fields = fn p ->
        Map.take(p, [:name, :description, :system_prompt, :mcp_config, :agents, :delivery])
        |> Map.put(:max, p.max_task_cost_usd && Decimal.to_string(p.max_task_cost_usd))
      end

      stage_fields = fn %Stage{} = stage ->
        stage
        |> Map.from_struct()
        |> Map.drop([:output_schema_json, :gates_text, :rules_text])
        |> Map.update!(:max_budget_usd, &(&1 && Decimal.to_string(&1)))
      end

      assert fields.(imported) == fields.(original)
      assert Enum.map(imported.stages, stage_fields) == Enum.map(original.stages, stage_fields)

      # Every template survives the round trip too.
      for template <- Pipelines.create_defaults(workspace) do
        {:ok, back} = Pipelines.import_yaml(other, Pipelines.export_yaml(template))
        assert Enum.map(back.stages, stage_fields) == Enum.map(template.stages, stage_fields)
      end

      # A YAML exported before stages lost their permission and approval
      # settings still imports.
      old =
        String.replace(
          yaml,
          "  - key: \"a\"\n",
          "  - key: \"a\"\n    pause_after: true\n    permission_profile: \"leitura\"\n    allowed_tools:\n      - \"Bash(git log:*)\"\n"
        )

      assert old =~ "permission_profile"

      assert {:ok, %{stages: [%Stage{key: "a"}]}} =
               Pipelines.import_yaml(workspace_fixture(), old)

      assert {:error, "YAML inválido" <> _} = Pipelines.import_yaml(other, "name: [")
      assert {:error, %Ecto.Changeset{}} = Pipelines.import_yaml(other, "name: Sem etapas")
      assert {:error, "precisa ser" <> _} = Pipelines.import_yaml(other, "- só uma lista")
    end

    test "a workspace does not see another's pipelines", %{workspace: workspace} do
      pipeline = pipeline_fixture(workspace)
      other = workspace_fixture()

      assert Pipelines.list_pipelines(other) == []
      assert_raise Ecto.NoResultsError, fn -> Pipelines.get_pipeline!(other, pipeline.id) end
    end
  end

  describe "Prompt" do
    @context %{
      task_id: "t1",
      title: "Botão quebrado",
      description: "O botão de login não responde",
      directory: "app",
      stage_index: 1,
      previous: [%Stage{key: "triagem", name: "Triagem"}],
      instructions: "Olhe o JS"
    }

    test "builds the contract, the rendered template and the instructions" do
      stage = %Stage{
        key: "investigacao",
        name: "Investigação",
        prompt: "Investigue: {{tarefa.descricao}} em {{tarefa.diretorio}}\n{{artefatos}}"
      }

      prompt = Prompt.build(stage, @context)

      assert prompt =~ ~s[etapa "Investigação" (2)]
      assert prompt =~ ".control-plane/t1/02-investigacao.md"
      assert prompt =~ "- Triagem: .control-plane/t1/01-triagem.md"
      assert prompt =~ "Investigue: O botão de login não responde em app"
      assert prompt =~ "Instruções adicionais de quem acompanha a tarefa"
      assert prompt =~ "Olhe o JS"

      first = Prompt.build(stage, %{@context | stage_index: 0, previous: [], instructions: nil})
      assert first =~ "(nenhum: esta é a primeira etapa)"
      refute first =~ "Instruções adicionais"
    end

    test "the output schema lets a blocked stage propose options" do
      schema = Prompt.output_schema(%Stage{output_schema: nil})
      assert schema["properties"]["opcoes"]["type"] == "array"
      refute "opcoes" in schema["required"]
    end

    test "the output schema always requires status and resumo" do
      assert %{"required" => ["status", "resumo"]} = Prompt.output_schema(%Stage{})

      schema =
        Prompt.output_schema(%Stage{
          output_schema: %{
            "type" => "object",
            "properties" => %{"nota" => %{"type" => "integer"}},
            "required" => ["nota"]
          }
        })

      assert Map.keys(schema["properties"]) |> Enum.sort() == [
               "nota",
               "opcoes",
               "perguntas",
               "resumo",
               "status"
             ]

      assert schema["required"] == ["status", "resumo", "nota"]
    end

    test "variables" do
      assert Prompt.unknown_variables("{{ tarefa.titulo }} {{x}} {{x}}") == ["x"]
      assert "artefatos" in Prompt.variables()
    end
  end
end
