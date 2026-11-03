defmodule ClaudeControlPlane.PipelinesTest do
  use ClaudeControlPlane.DataCase, async: true

  import ClaudeControlPlane.Fixtures

  alias ClaudeControlPlane.Pipelines
  alias ClaudeControlPlane.Pipelines.{Pipeline, Prompt, Stage}

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

    test "a stage's permissions: a known profile and tool rules as text", %{workspace: workspace} do
      stage = %{
        "name" => "Ler",
        "prompt" => "p",
        "permission_profile" => "leitura",
        "allowed_tools_text" => "Bash(git log:*)\n\nBash(rg:*)",
        "denied_tools_text" => "WebFetch"
      }

      {:ok, pipeline} =
        Pipelines.create_pipeline(workspace, %{"name" => "P", "stages" => [stage]})

      assert [
               %Stage{
                 permission_profile: "leitura",
                 allowed_tools: allowed,
                 denied_tools: ["WebFetch"]
               } = saved
             ] =
               pipeline.stages

      assert allowed == ["Bash(git log:*)", "Bash(rg:*)"]
      assert Stage.allowed_tools_text(saved) == "Bash(git log:*)\nBash(rg:*)"

      {:ok, pipeline} =
        Pipelines.create_pipeline(workspace, %{
          "name" => "Q",
          "stages" => [%{"name" => "E", "prompt" => "p"}]
        })

      assert [%Stage{permission_profile: "total"}] = pipeline.stages

      assert {:error, changeset} =
               Pipelines.create_pipeline(workspace, %{
                 "name" => "R",
                 "stages" => [Map.put(stage, "permission_profile", "root")]
               })

      assert [%{permission_profile: [_]}] = errors_on(changeset).stages
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
      assert [_, _] = Pipelines.create_defaults(workspace)
      assert Pipelines.create_defaults(workspace) == []

      names = workspace |> Pipelines.list_pipelines() |> Enum.map(& &1.name)
      assert names == ["Correção de bug", "Prompt único"]

      bug_fix = Enum.find(Pipelines.list_pipelines(workspace), &(&1.name == "Correção de bug"))

      assert Enum.map(bug_fix.stages, & &1.key) ==
               ~w(triagem investigacao reproducao implementacao auditoria pr)

      # Stages that only look do not get to change the code.
      assert Enum.map(bug_fix.stages, & &1.permission_profile) ==
               ~w(leitura leitura total total leitura total)
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

      assert Map.keys(schema["properties"]) |> Enum.sort() == ["nota", "resumo", "status"]
      assert schema["required"] == ["status", "resumo", "nota"]
    end

    test "variables" do
      assert Prompt.unknown_variables("{{ tarefa.titulo }} {{x}} {{x}}") == ["x"]
      assert "artefatos" in Prompt.variables()
    end
  end
end
