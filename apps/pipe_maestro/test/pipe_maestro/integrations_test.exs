defmodule PipeMaestro.IntegrationsTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{Audit, FakeForgejo, Integrations, Repo}
  alias PipeMaestro.Integrations.{Connection, LinkedRepo, Trigger}

  @hook "https://pm.test/api/integrations/x/webhook"

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    fake = FakeForgejo.start(repos: %{"acme/app" => %{}, "acme/site" => %{}})
    %{workspace: workspace, user: user, fake: fake, project: app_project_fixture(workspace)}
  end

  defp attrs(extra \\ %{}) do
    Map.merge(
      %{
        "name" => "Forgejo",
        "provider" => "forgejo",
        "base_url" => FakeForgejo.base_url(),
        "auth_kind" => "token",
        "token" => "tok"
      },
      extra
    )
  end

  defp actions(workspace), do: workspace |> Audit.list_events() |> Enum.map(& &1.action)

  describe "connections" do
    test "creating one checks the credential and keeps the bot and the version", ctx do
      assert {:ok, %Connection{} = connection} =
               Integrations.create_connection(ctx.workspace, ctx.user, attrs())

      assert connection.status == "active"
      assert connection.bot_login == "pipemaestro-bot"
      assert connection.bot_user_id == "7"
      assert connection.server_version == "17.0.1+gitea-1.22.0"
      assert connection.connected_by_id == ctx.user.id
      assert "integration.connected" in actions(ctx.workspace)
      assert [%Connection{name: "Forgejo"}] = Integrations.list_connections(ctx.workspace)
    end

    test "a refused token keeps the connection, in error", ctx do
      assert {:ok, connection} =
               Integrations.create_connection(
                 ctx.workspace,
                 ctx.user,
                 attrs(%{"token" => "errado"})
               )

      assert connection.status == "error"
      assert connection.last_error =~ "401"
    end

    test "an OAuth connection waits for someone to sign in", ctx do
      oauth =
        attrs(%{
          "auth_kind" => "oauth",
          "token" => nil,
          "oauth_client_id" => "cid",
          "oauth_client_secret" => "cs"
        })

      assert {:ok, %Connection{status: "pending"}} =
               Integrations.create_connection(ctx.workspace, ctx.user, oauth)
    end

    test "invalid attributes come back as a changeset", ctx do
      assert {:error, %Ecto.Changeset{}} =
               Integrations.create_connection(ctx.workspace, ctx.user, attrs(%{"name" => ""}))
    end

    test "editing re-checks and refuses the runner mode while a trigger needs the API", ctx do
      connection = connection_fixture(ctx.workspace)

      {:ok, repo} =
        Integrations.link_repo(
          connection,
          ctx.user,
          %{"full_name" => "acme/app", "project_id" => ctx.project.id},
          @hook
        )

      {:ok, _trigger} =
        Integrations.save_trigger(repo, ctx.user, %Trigger{}, %{
          "kind" => "comment",
          "command" => "/pm"
        })

      assert {:error, changeset} =
               Integrations.update_connection(connection, ctx.user, %{"api_mode" => "runner"})

      assert %{api_mode: [_]} = errors_on(changeset)

      assert {:ok, %Connection{name: "Outro nome", status: "active"}} =
               Integrations.update_connection(connection, ctx.user, %{"name" => "Outro nome"})

      assert "integration.updated" in actions(ctx.workspace)
    end

    test "removing one removes the webhooks the platform created", ctx do
      connection = connection_fixture(ctx.workspace)

      {:ok, _repo} =
        Integrations.link_repo(
          connection,
          ctx.user,
          %{"full_name" => "acme/app", "project_id" => ctx.project.id},
          @hook
        )

      assert [_hook] = FakeForgejo.repo(ctx.fake, "acme/app").hooks

      assert :ok = Integrations.delete_connection(connection, ctx.user)
      assert FakeForgejo.repo(ctx.fake, "acme/app").hooks == []
      assert Integrations.list_connections(ctx.workspace) == []
      assert "integration.removed" in actions(ctx.workspace)
    end

    test "rotating the webhook's secret updates the managed webhooks", ctx do
      connection = connection_fixture(ctx.workspace)

      {:ok, _repo} =
        Integrations.link_repo(
          connection,
          ctx.user,
          %{"full_name" => "acme/app", "project_id" => ctx.project.id},
          @hook
        )

      old = Connection.webhook_secret(connection)

      assert {:ok, connection} = Integrations.rotate_webhook_secret(connection, ctx.user, @hook)
      new = Connection.webhook_secret(connection)
      refute new == old
      assert [%{"config" => %{"secret" => ^new}}] = FakeForgejo.repo(ctx.fake, "acme/app").hooks
    end

    test "is scoped to the workspace", ctx do
      connection = connection_fixture(ctx.workspace)
      assert Integrations.get_connection!(ctx.workspace, connection.id).id == connection.id

      assert_raise Ecto.NoResultsError, fn ->
        Integrations.get_connection!(workspace_fixture(), connection.id)
      end
    end
  end

  describe "repositories" do
    setup ctx, do: %{connection: connection_fixture(ctx.workspace)}

    test "lists what the credential reaches", ctx do
      assert {:ok, [%{full_name: "acme/app"}, %{full_name: "acme/site"}], false} =
               Integrations.available_repos(ctx.connection, "acme")
    end

    test "linking creates the missing labels and the webhook", ctx do
      assert {:ok, %LinkedRepo{} = repo} =
               Integrations.link_repo(
                 ctx.connection,
                 ctx.user,
                 %{"full_name" => "Acme/App", "project_id" => ctx.project.id},
                 @hook
               )

      assert repo.full_name == "acme/app"
      assert repo.default_branch == "main"
      assert repo.webhook_status == "managed"
      assert repo.webhook_id

      fake_repo = FakeForgejo.repo(ctx.fake, "acme/app")

      assert Enum.map(fake_repo.labels, & &1["name"]) ==
               Enum.map(Integrations.Labels.defaults("pipemaestro"), & &1.name)

      secret = Connection.webhook_secret(ctx.connection)
      assert [%{"config" => %{"url" => @hook, "secret" => ^secret}}] = fake_repo.hooks
      assert "integration.repo_linked" in actions(ctx.workspace)
      assert [%LinkedRepo{full_name: "acme/app"}] = Integrations.list_repos(ctx.connection)
    end

    test "without rights on the webhook, the repository is linked for a manual one", ctx do
      FakeForgejo.fail(ctx.fake, {"POST", "/api/v1/repos/acme/app/hooks"}, 403)

      assert {:ok, %LinkedRepo{webhook_status: "manual", webhook_id: nil}} =
               Integrations.link_repo(
                 ctx.connection,
                 ctx.user,
                 %{"full_name" => "acme/app", "project_id" => ctx.project.id},
                 @hook
               )
    end

    test "refuses a repository the host does not have, twice the same one and another workspace's project",
         ctx do
      assert {:error, changeset} =
               Integrations.link_repo(
                 ctx.connection,
                 ctx.user,
                 %{"full_name" => "acme/nada"},
                 @hook
               )

      assert %{full_name: ["o host não encontrou o repositório" <> _]} = errors_on(changeset)

      {:ok, _} =
        Integrations.link_repo(ctx.connection, ctx.user, %{"full_name" => "acme/app"}, @hook)

      assert {:error, changeset} =
               Integrations.link_repo(
                 ctx.connection,
                 ctx.user,
                 %{"full_name" => "acme/app"},
                 @hook
               )

      assert %{full_name: ["já está vinculado"]} = errors_on(changeset)

      other = app_project_fixture(workspace_fixture())

      assert {:error, changeset} =
               Integrations.link_repo(
                 ctx.connection,
                 ctx.user,
                 %{"full_name" => "acme/site", "project_id" => other.id},
                 @hook
               )

      assert %{project_id: [_]} = errors_on(changeset)
    end

    test "unlinking removes the managed webhook and leaves the tasks without the link", ctx do
      {:ok, repo} =
        Integrations.link_repo(ctx.connection, ctx.user, %{"full_name" => "acme/app"}, @hook)

      assert :ok = Integrations.unlink_repo(repo, ctx.user)
      assert FakeForgejo.repo(ctx.fake, "acme/app").hooks == []
      assert Integrations.list_repos(ctx.connection) == []
      assert "integration.repo_unlinked" in actions(ctx.workspace)
    end
  end

  describe "triggers" do
    setup ctx do
      connection = connection_fixture(ctx.workspace)

      {:ok, repo} =
        Integrations.link_repo(
          connection,
          ctx.user,
          %{"full_name" => "acme/app", "project_id" => ctx.project.id},
          @hook
        )

      %{connection: connection, repo: repo}
    end

    test "a new trigger starts from the repository's label and the person setting it up", ctx do
      trigger = Integrations.new_trigger(ctx.repo, ctx.user)

      assert {trigger.label, trigger.command, trigger.acting_user_id} ==
               {"pipemaestro", "/pipemaestro", ctx.user.id}
    end

    test "saves, lists and removes triggers", ctx do
      pipeline = pipeline_fixture(ctx.workspace)

      assert {:ok, trigger} =
               Integrations.save_trigger(
                 ctx.repo,
                 ctx.user,
                 Integrations.new_trigger(ctx.repo, ctx.user),
                 %{
                   "kind" => "label",
                   "pipeline_id" => pipeline.id
                 }
               )

      assert trigger.workspace_id == ctx.workspace.id
      assert [%Trigger{kind: "label"}] = Integrations.list_triggers(ctx.repo)
      assert "integration.trigger_saved" in actions(ctx.workspace)

      assert {:ok, %Trigger{enabled: false}} =
               Integrations.save_trigger(ctx.repo, ctx.user, trigger, %{"enabled" => "false"})

      assert :ok = Integrations.delete_trigger(trigger, ctx.user)
      assert Integrations.list_triggers(ctx.repo) == []
    end

    test "refuses another workspace's pipeline and someone outside the workspace", ctx do
      other = workspace_fixture()

      assert {:error, changeset} =
               Integrations.save_trigger(ctx.repo, ctx.user, %Trigger{}, %{
                 "kind" => "opened",
                 "pipeline_id" => pipeline_fixture(other).id
               })

      assert %{pipeline_id: [_]} = errors_on(changeset)

      assert {:error, changeset} =
               Integrations.save_trigger(ctx.repo, ctx.user, %Trigger{}, %{
                 "kind" => "opened",
                 "acting_user_id" => member_fixture(other).id
               })

      assert %{acting_user_id: [_]} = errors_on(changeset)
    end

    test "follows the connection's mode", ctx do
      {:ok, _} = Repo.update(Ecto.Changeset.change(ctx.connection, api_mode: "runner"))
      repo = Repo.reload!(ctx.repo)

      assert {:error, changeset} =
               Integrations.save_trigger(repo, ctx.user, %Trigger{}, %{"kind" => "opened"})

      assert %{kind: [_]} = errors_on(changeset)
    end
  end
end
