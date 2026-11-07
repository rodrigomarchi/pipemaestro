defmodule PipeMaestroWeb.TaskComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Tasks.StageRun
  alias PipeMaestroWeb.TaskComponents

  test "files show their lines, or what happened to them outside git, or that they are binary" do
    html =
      render_component(&TaskComponents.file_list/1,
        files: [
          %{"path" => "a.ex", "added" => 2, "removed" => 1},
          %{"path" => "logo.png", "added" => nil, "removed" => nil},
          %{"path" => "notas.md", "added" => nil, "removed" => nil, "status" => "new"},
          %{"path" => "velho.md", "added" => nil, "removed" => nil, "status" => "removed"},
          %{"path" => "mudou.md", "added" => nil, "removed" => nil, "status" => "modified"}
        ]
      )

    assert html =~ "+2"
    assert html =~ ~r/binário.*logo\.png/s
    assert html =~ ~r/novo.*notas\.md/s
    assert html =~ ~r/removido.*velho\.md/s
    assert html =~ ~r/alterado.*mudou\.md/s
  end

  describe "stage_run_session/1" do
    defp run_with(context, resumed) do
      job = Map.put(%Job{context: context}, :session_resumed, resumed)
      %StageRun{key: "b", attempt: 1, status: :passed, job: job}
    end

    defp session(run), do: render_component(&TaskComponents.stage_run_session/1, run: run)

    test "a run that continued the stage before says so" do
      html = session(run_with(%{"resume_session_id" => "s-1"}, true))
      assert html =~ ~s(data-testid="stage-run-session-b-1")
      assert html =~ "Continuou a etapa anterior"
    end

    test "a run still going that asked to continue says so too" do
      assert session(run_with(%{"resume_session_id" => "s-1"}, nil)) =~
               "Continuou a etapa anterior"
    end

    test "a run that could not continue says it started fresh" do
      html = session(run_with(%{"resume_session_id" => "ausente"}, false))
      assert html =~ ~s(data-testid="stage-run-session-b-1")
      assert html =~ "Começou do zero: a sessão anterior não estava disponível"
    end

    test "a run that did not ask to continue shows nothing" do
      refute session(run_with(%{}, nil)) =~ "stage-run-session"

      refute session(%StageRun{key: "a", attempt: 1, status: :running, job: nil}) =~
               "stage-run-session"
    end
  end
end
