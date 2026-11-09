defmodule PipeMaestro.TaskSourcesTest.FakeSource do
  @moduledoc false
  # A task source that exists only in this test: tickets of a tracker with no
  # code. It tells the test process what the platform asked of it.
  @behaviour PipeMaestro.TaskSources.Source

  alias PipeMaestro.TaskSources.Item

  defp tell(message) do
    case Application.get_env(:pipe_maestro, :fake_task_source_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _none -> :ok
    end

    :ok
  end

  @impl true
  def receive_webhook(key, _headers, raw_body, _opts) do
    tell({:fake_webhook, key, raw_body})
    {:ok, :taken}
  end

  @impl true
  def fetch_item(origin) do
    {:ok,
     struct!(Item,
       source: "fake",
       external_id: origin.external_id,
       url: origin.url,
       title: "Ticket lido de novo",
       description: "Descrição lida de novo",
       author: "ana",
       labels: [],
       priority: "alta",
       kind: "Ticket",
       ref: origin.ref,
       linked_repo_id: nil
     )}
  end

  @impl true
  def task_changed(task) do
    tell({:fake_task_changed, task.id, task.status})
  end

  @impl true
  def triage_finished(job), do: tell({:fake_triage_finished, job.id})

  @impl true
  def runner_delivery(%{pending_source_note: note}) when is_binary(note),
    do: %{"fake_note" => note}

  def runner_delivery(_task), do: %{}

  @impl true
  def pr_reference(task), do: "Ticket #{task.source_id}: #{task.source_url}"

  @impl true
  def reply(origin, reply_to, text), do: tell({:fake_reply, origin.external_id, reply_to, text})
end

defmodule PipeMaestro.TaskSourcesTest do
  # The registry of sources is global configuration, and the dispatcher a
  # named process: the module runs alone.
  use PipeMaestro.DataCase, async: false

  import PipeMaestro.Fixtures

  alias PipeMaestro.{Jobs, Tasks, TaskSources}
  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Tasks.Task
  alias PipeMaestro.TaskSources.{Commands, Dispatcher, Item, Origin}
  alias PipeMaestro.TaskSourcesTest.FakeSource

  @url "https://tracker.example.com/browse/FAKE-1"

  setup do
    previous = Application.get_env(:pipe_maestro, TaskSources)
    sources = Keyword.get(previous || [], :sources, %{})

    Application.put_env(
      :pipe_maestro,
      TaskSources,
      Keyword.put(previous || [], :sources, Map.put(sources, "fake", FakeSource))
    )

    Application.put_env(:pipe_maestro, :fake_task_source_pid, self())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:pipe_maestro, TaskSources, previous),
        else: Application.delete_env(:pipe_maestro, TaskSources)

      Application.delete_env(:pipe_maestro, :fake_task_source_pid)
    end)

    workspace = workspace_fixture()
    user = member_fixture(workspace)
    {runner, _token} = runner_fixture(workspace, user)

    # A runner that writes proposals (`scratch`), offering `app` in git.
    {:ok, runner} =
      PipeMaestro.Runners.record_hello(
        runner,
        hello_fixture(%{
          capabilities: ["scratch"],
          directories: [%{"name" => "app", "git" => true}]
        })
      )

    pipeline =
      pipeline_fixture(workspace, %{
        "name" => "Com PR",
        "delivery" => "pr",
        "stages" => [%{"key" => "a", "name" => "Etapa A", "prompt" => "Faça A"}]
      })

    %{
      workspace: workspace,
      user: user,
      runner: runner,
      project: project_fixture(runner, "app"),
      pipeline: pipeline
    }
  end

  defp item(attrs \\ []) do
    struct!(
      Item,
      Keyword.merge(
        [
          source: "fake",
          external_id: "FAKE-1",
          url: @url,
          title: "Exportar o relatório",
          description: "O relatório mensal precisa sair em CSV.",
          author: "ana",
          labels: ["relatorio"],
          priority: "alta",
          kind: "Ticket",
          ref: %{"board" => "OPS"},
          linked_repo_id: nil
        ],
        attrs
      )
    )
  end

  defp target(ctx, mode \\ "task") do
    %{
      mode: mode,
      project_id: ctx.project.id,
      pipeline_id: ctx.pipeline.id,
      acting_user_id: ctx.user.id,
      auto_approve: true
    }
  end

  defp start_task(ctx) do
    {:ok, %Task{} = task} = TaskSources.start(ctx.workspace, item(), target(ctx))
    task
  end

  # Plays the runner: starts the task's current job and reports its end.
  defp run_current(ctx, task, report) do
    task = Tasks.get_task!(ctx.workspace, task.id)
    job = (Enum.find(task.stage_runs, &(&1.status == :running)) || List.last(task.stage_runs)).job
    {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

    payload =
      Map.merge(
        %{
          "status" => "succeeded",
          "exit_code" => 0,
          "structured_output" => %{"status" => "ok", "resumo" => "feito"},
          "artifact" => "# Artefato",
          "workdir" => "/w/worktrees/#{task.id}"
        },
        report
      )

    {:ok, _job} = Jobs.finish_job(ctx.runner, job.id, payload)
    Tasks.get_task!(ctx.workspace, task.id)
  end

  defp awaiting(ctx) do
    task = start_task(ctx)

    task =
      run_current(ctx, task, %{
        "structured_output" => %{"status" => "bloqueado", "resumo" => "Qual formato de data?"}
      })

    assert %Task{status: :awaiting_decision} = task
    task
  end

  describe "the registry" do
    test "finds a source by its key", _ctx do
      assert TaskSources.fetch("fake") == {:ok, FakeSource}
      assert TaskSources.fetch("ninguem") == :error
      assert {"fake", FakeSource} in TaskSources.sources()
    end

    test "the issues of a git host are a source registered by configuration", _ctx do
      assert TaskSources.fetch("git_issue") == {:ok, PipeMaestro.Integrations.IssueSource}
    end

    test "a webhook goes to the source of its key", _ctx do
      assert TaskSources.receive_webhook("fake", "conta-1", %{}, ~s({"ticket":"FAKE-1"})) ==
               {:ok, :taken}

      assert_receive {:fake_webhook, "conta-1", ~s({"ticket":"FAKE-1"})}

      assert TaskSources.receive_webhook("ninguem", nil, %{}, "{}") == {:error, :not_found}
    end
  end

  describe "a new source, without touching the task engine" do
    test "creates a task from its normalized item, on the trigger's project and pipeline", ctx do
      task = start_task(ctx)

      assert %Task{} = task

      assert %{
               source: "fake",
               source_id: "FAKE-1",
               source_url: @url,
               source_ref: %{"board" => "OPS"},
               linked_repo_id: nil,
               title: "Exportar o relatório",
               project_id: project_id,
               pipeline_id: pipeline_id,
               created_by_user_id: user_id
             } = task

      assert {project_id, pipeline_id, user_id} == {ctx.project.id, ctx.pipeline.id, ctx.user.id}
      assert task.prompt == "O relatório mensal precisa sair em CSV.\n\nTicket: #{@url}"

      assert TaskSources.active?(ctx.workspace, "fake", "FAKE-1")
      assert Tasks.active_for_source?(ctx.workspace, "fake", "FAKE-1")
      refute TaskSources.active?(ctx.workspace, "fake", "FAKE-2")
    end

    test "an item without a description takes its title as the request", ctx do
      {:ok, task} = TaskSources.start(ctx.workspace, item(description: nil), target(ctx))
      assert task.prompt == "Exportar o relatório\n\nTicket: #{@url}"
    end

    test "a trigger without a person to act for creates nothing", ctx do
      assert TaskSources.start(ctx.workspace, item(), %{target(ctx) | acting_user_id: nil}) ==
               {:error, :no_acting_user}
    end

    test "a triage keeps the origin in the proposal and tells the source how it ended", ctx do
      assert {:ok, %Job{} = job} = TaskSources.start(ctx.workspace, item(), target(ctx, "triage"))

      input = job.context["proposal"]["input"]

      origin = Origin.from_input(input)
      assert origin.__struct__ == Origin
      assert %{source: "fake", external_id: "FAKE-1", url: @url} = origin

      assert TaskSources.active?(ctx.workspace, "fake", "FAKE-1")

      assert {:error, :already_triaging} =
               TaskSources.start(ctx.workspace, item(), target(ctx, "triage"))

      assert TaskSources.triage_finished(job) == :ok
      assert_receive {:fake_triage_finished, job_id}
      assert job_id == job.id
    end

    test "each change of the task is reflected through its source", ctx do
      :ok = Tasks.subscribe(:sourced)
      start_supervised!(Dispatcher)

      task = start_task(ctx)
      task_id = task.id

      assert_receive {:source_task_updated, %{id: ^task_id, source: "fake"}}
      assert_receive {:fake_task_changed, ^task_id, _status}

      {:ok, _canceled} = Tasks.cancel_task(task, by: ctx.user)
      assert_receive {:fake_task_changed, ^task_id, :canceled}
    end

    test "a task without a source signals nothing to the sources", ctx do
      :ok = Tasks.subscribe(:sourced)

      {:ok, task} =
        Tasks.create_task(ctx.user, ctx.workspace, %{
          "title" => "À mão",
          "prompt" => "Sem origem",
          "pipeline_id" => ctx.pipeline.id,
          "project_id" => ctx.project.id
        })

      assert task.source == nil
      refute_receive {:source_task_updated, _task}
    end

    test "the pull request names the origin the way the source says", ctx do
      task = start_task(ctx)
      assert Tasks.pr_block(task) =~ "Ticket FAKE-1: #{@url}"
      refute Tasks.pr_block(task) =~ "Closes"
    end

    test "commands reach the same functions as the screen", ctx do
      task = awaiting(ctx)

      {:ok, command} = Commands.parse("/pipemaestro refazer use ISO 8601", "/pipemaestro")

      assert {:ok, %Task{status: :running}} =
               TaskSources.apply_command(task, command, via: "Fake: ana")

      [decision] = Tasks.list_decisions(task)
      assert decision.instructions =~ "use ISO 8601"
      assert decision.decided_via == "Fake: ana"

      {:ok, again} = Commands.parse("/pipemaestro seguir", "/pipemaestro")

      assert TaskSources.apply_command(task, again, via: "Fake: ana") ==
               {:error, "A tarefa não espera uma decisão agora."}

      {:ok, cancel} = Commands.parse("/pipemaestro cancelar", "/pipemaestro")

      assert {:ok, %Task{status: :canceled}} =
               TaskSources.apply_command(task, cancel, via: "Fake: ana")
    end

    test "a decision leaves a note the source delivers with the next stage", ctx do
      task = awaiting(ctx)
      {:ok, command} = Commands.parse("/pipemaestro refazer use ISO 8601", "/pipemaestro")
      {:ok, task} = TaskSources.apply_command(task, command, via: "Fake: ana")

      task = Tasks.get_task!(ctx.workspace, task.id)
      job = Enum.find(task.stage_runs, &(&1.status == :running)).job
      note = job.context["delivery"]["fake_note"]

      assert note =~ "Etapa A"
      assert note =~ "use ISO 8601"
      # Delivered with the stage, the note is no longer pending.
      assert task.pending_source_note == nil
    end

    test "the source reads its item again and answers people", _ctx do
      origin = %{external_id: "FAKE-1", url: @url, ref: %{}}
      assert {:ok, read} = FakeSource.fetch_item(origin)
      assert read.__struct__ == Item
      assert %{title: "Ticket lido de novo", priority: "alta"} = read

      assert FakeSource.reply(origin, :comentario, "Não entendi") == :ok
      assert_receive {:fake_reply, "FAKE-1", :comentario, "Não entendi"}
    end
  end
end
