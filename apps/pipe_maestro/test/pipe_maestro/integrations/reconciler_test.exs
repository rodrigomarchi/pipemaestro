defmodule PipeMaestro.Integrations.ReconcilerTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{FakeForgejo, Integrations, Proposals, Repo, Runners, Tasks}

  alias PipeMaestro.Integrations.{
    Delivery,
    Ingest,
    LinkedRepo,
    PrOutcomes,
    Reconciler
  }

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    fake = FakeForgejo.start(permissions: %{"ana" => "write"})
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})

    {:ok, runner} =
      Runners.record_hello(
        runner,
        hello_fixture(%{
          capabilities: ["scratch"],
          directories: [%{"name" => "app", "git" => true}]
        })
      )

    connection = connection_fixture(workspace)
    project = project_fixture(runner, "app")

    {:ok, repo} =
      Integrations.link_repo(
        connection,
        user,
        %{"full_name" => "acme/app", "project_id" => project.id},
        "https://pm.test/hook"
      )

    {:ok, _} =
      Integrations.save_trigger(repo, user, Integrations.new_trigger(repo, user), %{
        "kind" => "label",
        "label" => "pipemaestro"
      })

    # The repository was linked a while ago.
    an_hour_ago = DateTime.utc_now(:second) |> DateTime.add(-3600)

    repo =
      repo
      |> Ecto.Changeset.change(synced_at: an_hour_ago, inserted_at: an_hour_ago)
      |> Repo.update!()

    %{
      workspace: workspace,
      user: user,
      fake: fake,
      connection: connection,
      repo: repo,
      project: project,
      runner: runner,
      opts: [presence: fn _ -> MapSet.new([runner.id]) end]
    }
  end

  # The project loses its runner (deleted), or gets it back.
  defp put_runner(ctx, runner_id),
    do:
      ctx.project
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.force_change(:runner_id, runner_id)
      |> Repo.update!()

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp triages(ctx), do: length(Proposals.list(ctx.workspace, %{"kind" => "task"}))

  test "an issue labeled while the webhook was lost starts the triage, once", ctx do
    FakeForgejo.put_issue(ctx.fake, "acme/app", %{
      "number" => 5,
      "labels" => ["pipemaestro"],
      "updated_at" => now_iso()
    })

    FakeForgejo.put_issue(ctx.fake, "acme/app", %{
      "number" => 6,
      "labels" => ["bug"],
      "updated_at" => now_iso()
    })

    assert %{issues: 2} = Reconciler.run(DateTime.utc_now(), ctx.opts)
    assert triages(ctx) == 1

    assert [%Delivery{source: "reconcile", status: "processed", issue_number: 5}] =
             Repo.all(from d in Delivery, where: d.status == "processed")

    Reconciler.run(DateTime.utc_now(), ctx.opts)
    assert triages(ctx) == 1
  end

  test "an issue the webhook already took does not fire again", ctx do
    FakeForgejo.put_issue(ctx.fake, "acme/app", %{
      "number" => 5,
      "labels" => ["pipemaestro"],
      "updated_at" => now_iso()
    })

    issue = %{
      number: 5,
      title: "Issue 5",
      body: "",
      url: "https://forge.test/acme/app/issues/5",
      state: "open",
      author: "ana",
      labels: ["pipemaestro"],
      updated_at: DateTime.utc_now(:second)
    }

    {name, payload} =
      Integrations.provider(ctx.connection).synthetic_event(:labels, "acme/app", issue)

    {:ok, _} = Ingest.ingest_event(ctx.connection, "webhook-like", name, payload, ctx.opts)

    Reconciler.run(DateTime.utc_now(), ctx.opts)
    assert triages(ctx) == 1
  end

  test "reads only what changed since the last sync, and moves it forward", ctx do
    old = DateTime.utc_now() |> DateTime.add(-7200) |> DateTime.to_iso8601()

    FakeForgejo.put_issue(ctx.fake, "acme/app", %{
      "number" => 5,
      "labels" => ["pipemaestro"],
      "updated_at" => old
    })

    now = DateTime.utc_now()

    assert %{issues: 0} = Reconciler.run(now, ctx.opts)
    assert DateTime.compare(Repo.reload!(ctx.repo).synced_at, DateTime.add(now, -1)) == :gt
  end

  test "tries again a delivery that waited for a runner", ctx do
    FakeForgejo.put_issue(ctx.fake, "acme/app", %{
      "number" => 5,
      "labels" => ["pipemaestro"],
      "updated_at" => now_iso()
    })

    put_runner(ctx, nil)
    Reconciler.run(DateTime.utc_now(), ctx.opts)
    assert [%Delivery{status: "waiting_runner"}] = Repo.all(Delivery)
    put_runner(ctx, ctx.runner.id)

    assert %{retried: 1} = Reconciler.run(DateTime.utc_now(), ctx.opts)
    assert triages(ctx) == 1
  end

  test "takes again a delivery whose processing was lost", ctx do
    FakeForgejo.put_issue(ctx.fake, "acme/app", %{
      "number" => 5,
      "labels" => ["pipemaestro"],
      "updated_at" => now_iso()
    })

    issue = %{
      number: 5,
      title: "Issue 5",
      body: "",
      url: "https://forge.test/acme/app/issues/5",
      state: "open",
      author: "ana",
      labels: ["pipemaestro"],
      updated_at: DateTime.utc_now(:second)
    }

    {name, payload} =
      Integrations.provider(ctx.connection).synthetic_event(:labels, "acme/app", issue)

    {:ok, headers_delivery} = Ingest.ingest_event(ctx.connection, "perdida", "push", %{})

    lost =
      headers_delivery
      |> Ecto.Changeset.change(
        status: "received",
        event: name,
        payload: payload,
        attempts: 0,
        inserted_at: DateTime.add(DateTime.utc_now(), -900)
      )
      |> Repo.update!()

    put_runner(ctx, nil)
    Reconciler.run(DateTime.utc_now(), ctx.opts)
    assert %Delivery{status: "waiting_runner", attempts: 1} = Repo.reload!(lost)
  end

  test "skips connections the platform must not call and repositories without readable triggers",
       ctx do
    FakeForgejo.put_issue(ctx.fake, "acme/app", %{
      "number" => 5,
      "labels" => ["pipemaestro"],
      "updated_at" => now_iso()
    })

    ctx.connection |> Ecto.Changeset.change(status: "error") |> Repo.update!()

    assert %{issues: 0} = Reconciler.run(DateTime.utc_now(), ctx.opts)
    assert Repo.all(Delivery) == []
  end

  test "pages through many issues", ctx do
    for n <- 1..60,
        do:
          FakeForgejo.put_issue(ctx.fake, "acme/app", %{"number" => n, "updated_at" => now_iso()})

    assert %{issues: 60} = Reconciler.run(DateTime.utc_now(), ctx.opts)
  end

  test "syncs one repository on demand", ctx do
    FakeForgejo.put_issue(ctx.fake, "acme/app", %{
      "number" => 5,
      "labels" => ["pipemaestro"],
      "updated_at" => now_iso()
    })

    [%LinkedRepo{} = repo] = Integrations.list_repos(ctx.connection)

    assert Reconciler.sync_repo(repo, DateTime.utc_now(), ctx.opts) == 1
    assert triages(ctx) == 1
  end

  describe "the outcome of the pull requests" do
    setup ctx do
      {:ok, task} =
        Tasks.create_task(
          ctx.user,
          ctx.workspace,
          %{
            "title" => "Corrige login",
            "prompt" => "O login quebra.",
            "pipeline_id" => pipeline_fixture(ctx.workspace).id,
            "project_id" => ctx.project.id,
            "issue_url" => "https://forge.test/acme/app/issues/3"
          },
          issue: %{linked_repo_id: ctx.repo.id, issue_number: 3}
        )

      task =
        task
        |> Ecto.Changeset.change(
          status: :succeeded,
          head_sha: "p1",
          pr_url: "https://forge.test/acme/app/pulls/7",
          issue_feedback: %{"pr_number" => 7},
          finished_at: DateTime.add(DateTime.utc_now(:second), -3_600)
        )
        |> Repo.update!()

      FakeForgejo.put_pull(ctx.fake, "acme/app", %{
        "number" => 7,
        "state" => "open",
        "head" => %{"ref" => task.branch, "sha" => "p1"},
        "base" => %{"ref" => "main"},
        "html_url" => "https://forge.test/acme/app/pulls/7",
        "commits" => [FakeForgejo.commit_json("p1")]
      })

      PrOutcomes.ready(task)
      %{task: task}
    end

    test "a merge the webhook missed is found on the host, with its date", ctx do
      FakeForgejo.edit_pull(
        ctx.fake,
        "acme/app",
        7,
        &Map.merge(&1, %{
          "state" => "closed",
          "merged" => true,
          "merged_at" => "2026-11-05T10:00:00Z",
          "closed_at" => "2026-11-05T10:00:00Z",
          "commits" => [FakeForgejo.commit_json("p1"), FakeForgejo.commit_json("h1")]
        })
      )

      assert %{outcomes: 1} = Reconciler.run(DateTime.utc_now(), ctx.opts)

      assert %{
               state: "merged",
               merged_at: ~U[2026-11-05 10:00:00Z],
               human_shas: ["h1"],
               commits_final: true
             } = PrOutcomes.get(ctx.task.id)

      # Settled: the next pass leaves it alone.
      assert %{outcomes: 0} = Reconciler.run(DateTime.utc_now(), ctx.opts)
    end

    test "a host that fails is kept for the next pass, and the pass goes on", ctx do
      FakeForgejo.fail(ctx.fake, {"GET", "/api/v1/repos/acme/app/pulls/7"}, 500, 1)

      assert %{outcomes: 0} = Reconciler.run(DateTime.utc_now(), ctx.opts)
      assert %{state: "open", commits_error: error} = PrOutcomes.get(ctx.task.id)
      assert is_binary(error)

      FakeForgejo.edit_pull(
        ctx.fake,
        "acme/app",
        7,
        &Map.merge(&1, %{"state" => "closed", "closed_at" => "2026-11-06T09:00:00Z"})
      )

      assert %{outcomes: 1} = Reconciler.run(DateTime.utc_now(), ctx.opts)

      assert %{state: "closed", closed_at: ~U[2026-11-06 09:00:00Z], commits_error: nil} =
               PrOutcomes.get(ctx.task.id)
    end
  end
end
