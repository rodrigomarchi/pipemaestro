defmodule PipeMaestroWeb.IntegrationLiveTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.{FakeForgejo, Integrations, Repo}
  alias PipeMaestro.Integrations.{Connection, Ingest}

  setup :register_and_log_in_member

  setup %{workspace: workspace} do
    %{
      fake: FakeForgejo.start(repos: %{"acme/app" => %{}, "acme/site" => %{}}),
      project: app_project_fixture(workspace)
    }
  end

  defp ipath(ctx, suffix \\ ""), do: ~p"/w/#{ctx.workspace.slug}/integrations" <> suffix

  describe "index" do
    test "a member who is not an admin is sent away", ctx do
      member = member_fixture(ctx.workspace)

      assert {:error, {:live_redirect, %{flash: %{"error" => _}}}} =
               live(log_in_user(ctx.conn, member), ipath(ctx))
    end

    test "shows the empty state and the connections", ctx do
      {:ok, view, _html} = live(ctx.conn, ipath(ctx))
      assert has_element?(view, "[data-testid=no-integrations]")

      connection_fixture(ctx.workspace, %{"name" => "Forgejo da casa"})
      {:ok, view, _html} = live(ctx.conn, ipath(ctx))
      assert has_element?(view, "[data-testid=integration-forgejo-da-casa]")

      assert view |> element("[data-testid=integration-status-forgejo-da-casa]") |> render() =~
               "ativa"
    end
  end

  describe "form" do
    test "creates a token connection and shows who it signs in as", ctx do
      {:ok, view, _html} = live(ctx.conn, ipath(ctx, "/new"))

      view
      |> form("#integration-form",
        connection: %{
          name: "Forgejo",
          base_url: FakeForgejo.base_url(),
          auth_kind: "token",
          token: "tok",
          api_mode: "control_plane"
        }
      )
      |> render_submit()

      [connection] = Integrations.list_connections(ctx.workspace)
      assert_redirect(view, ipath(ctx, "/#{connection.id}"))

      {:ok, view, _html} = live(ctx.conn, ipath(ctx, "/#{connection.id}"))
      assert view |> element("[data-testid=integration-bot]") |> render() =~ "pipemaestro-bot"
    end

    test "a refused token is saved in error, with the host's answer", ctx do
      {:ok, view, _html} = live(ctx.conn, ipath(ctx, "/new"))

      view
      |> form("#integration-form",
        connection: %{
          name: "Forgejo",
          base_url: FakeForgejo.base_url(),
          auth_kind: "token",
          token: "errado"
        }
      )
      |> render_submit()

      assert [%Connection{status: "error"}] = Integrations.list_connections(ctx.workspace)
    end

    test "shows the errors and the OAuth fields", ctx do
      {:ok, view, _html} = live(ctx.conn, ipath(ctx, "/new"))

      html =
        view
        |> form("#integration-form",
          connection: %{name: "", base_url: "ftp://x", auth_kind: "token"}
        )
        |> render_submit()

      assert html =~ "dê um nome à conexão"

      view |> form("#integration-form", connection: %{auth_kind: "oauth"}) |> render_change()
      assert has_element?(view, "[data-testid=integration-oauth-redirect]")

      assert view |> element("[data-testid=integration-oauth-redirect]") |> render() =~
               "/integrations/oauth/callback"
    end

    test "an OAuth connection is saved and sends the person to authorize with PKCE", ctx do
      {:ok, view, _html} = live(ctx.conn, ipath(ctx, "/new"))
      view |> form("#integration-form", connection: %{auth_kind: "oauth"}) |> render_change()

      assert {:error, {:redirect, %{to: url}}} =
               view
               |> form("#integration-form",
                 connection: %{
                   name: "Forgejo",
                   base_url: FakeForgejo.base_url(),
                   auth_kind: "oauth",
                   oauth_client_id: "cid",
                   oauth_client_secret: "cs"
                 }
               )
               |> render_submit()

      assert url =~ FakeForgejo.base_url() <> "/login/oauth/authorize?"
      assert url =~ "code_challenge_method=S256"
      assert [%Connection{status: "pending"}] = Integrations.list_connections(ctx.workspace)
    end

    test "edits a connection, keeping the token", ctx do
      connection = connection_fixture(ctx.workspace, %{"name" => "Velho"})
      {:ok, view, _html} = live(ctx.conn, ipath(ctx, "/#{connection.id}/edit"))

      view |> form("#integration-form", connection: %{name: "Novo", token: ""}) |> render_submit()
      assert_redirect(view, ipath(ctx, "/#{connection.id}"))
      assert %Connection{name: "Novo"} = updated = Repo.reload!(connection)
      assert Connection.credentials(updated) == %{"token" => "tok"}
    end
  end

  describe "show" do
    setup ctx, do: %{connection: connection_fixture(ctx.workspace)}

    test "links a repository found by search, creating the webhook", ctx do
      {:ok, view, _html} = live(ctx.conn, ipath(ctx, "/#{ctx.connection.id}"))
      assert has_element?(view, "[data-testid=no-repos]")

      view |> element("[data-testid=repo-link-open]") |> render_click()
      view |> form("#repo-search-form", search: %{query: "app"}) |> render_change()
      refute has_element?(view, "[data-testid=repo-option-acme-site]")
      view |> element("[data-testid=repo-option-acme-app]") |> render_click()
      view |> form("#repo-link-form", repo: %{project_id: ctx.project.id}) |> render_submit()

      [repo] = Integrations.list_repos(ctx.connection)
      assert_redirect(view, ipath(ctx, "/#{ctx.connection.id}/repos/#{repo.id}"))
      assert repo.webhook_status == "managed"
      assert [_hook] = FakeForgejo.repo(ctx.fake, "acme/app").hooks

      {:ok, view, _html} = live(ctx.conn, ipath(ctx, "/#{ctx.connection.id}"))

      assert view |> element("[data-testid=repo-webhook-acme-app]") |> render() =~
               "webhook criado"
    end

    test "without rights on the webhook, the repository waits for a manual one", ctx do
      FakeForgejo.fail(ctx.fake, {"POST", "/api/v1/repos/acme/app/hooks"}, 403)

      {:ok, _repo} =
        Integrations.link_repo(
          ctx.connection,
          ctx.user,
          %{"full_name" => "acme/app", "project_id" => ctx.project.id},
          "https://x"
        )

      {:ok, view, _html} = live(ctx.conn, ipath(ctx, "/#{ctx.connection.id}"))

      assert view |> element("[data-testid=repo-webhook-acme-app]") |> render() =~
               "webhook manual"

      assert view |> element("[data-testid=integration-webhook-url]") |> render() =~
               "/api/integrations/#{ctx.connection.id}/webhook"
    end

    test "reveals and rotates the webhook's secret", ctx do
      {:ok, _repo} =
        Integrations.link_repo(
          ctx.connection,
          ctx.user,
          %{"full_name" => "acme/app", "project_id" => ctx.project.id},
          "https://x"
        )

      {:ok, view, _html} = live(ctx.conn, ipath(ctx, "/#{ctx.connection.id}"))
      secret = Connection.webhook_secret(ctx.connection)

      refute render(view) =~ secret
      view |> element("[data-testid=integration-webhook-secret-reveal]") |> render_click()
      assert view |> element("[data-testid=integration-webhook-secret]") |> render() =~ secret

      view |> element("[data-testid=integration-webhook-secret-rotate]") |> render_click()
      new = Connection.webhook_secret(Repo.reload!(ctx.connection))
      refute new == secret
      assert [%{"config" => %{"secret" => ^new}}] = FakeForgejo.repo(ctx.fake, "acme/app").hooks
    end

    test "tests the connection and removes it", ctx do
      {:ok, view, _html} = live(ctx.conn, ipath(ctx, "/#{ctx.connection.id}"))

      view |> element("[data-testid=integration-check]") |> render_click()
      assert render_async(view) =~ "pipemaestro-bot"

      view |> element("[data-testid=integration-delete]") |> render_click()
      assert_redirect(view, ipath(ctx))
      assert Integrations.list_connections(ctx.workspace) == []
    end
  end

  describe "repository" do
    setup ctx do
      connection = connection_fixture(ctx.workspace)

      {:ok, repo} =
        Integrations.link_repo(
          connection,
          ctx.user,
          %{"full_name" => "acme/app", "project_id" => ctx.project.id},
          "https://x"
        )

      %{
        connection: connection,
        repo: repo,
        pipeline: pipeline_fixture(ctx.workspace, %{"name" => "Correção de bug"})
      }
    end

    defp repo_path(ctx), do: ipath(ctx, "/#{ctx.connection.id}/repos/#{ctx.repo.id}")

    test "adds a label trigger and a comment trigger", ctx do
      {:ok, view, _html} = live(ctx.conn, repo_path(ctx))
      assert has_element?(view, "[data-testid=no-triggers]")

      view |> element("[data-testid=trigger-new]") |> render_click()

      view
      |> form("#trigger-form", trigger: %{kind: "label", label: "pipemaestro", mode: "triage"})
      |> render_submit()

      assert has_element?(view, "[data-testid=trigger-label-pipemaestro]")

      view |> element("[data-testid=trigger-new]") |> render_click()
      view |> form("#trigger-form", trigger: %{kind: "comment"}) |> render_change()
      refute has_element?(view, "[data-testid=trigger-pipeline-preview]")

      view
      |> form("#trigger-form", trigger: %{kind: "comment", pipeline_id: ctx.pipeline.id})
      |> render_change()

      assert has_element?(
               view,
               "[data-testid=trigger-pipeline-preview] [data-testid=diagram-stage-0]"
             )

      view
      |> form("#trigger-form",
        trigger: %{kind: "comment", command: "/pipemaestro", pipeline_id: ctx.pipeline.id}
      )
      |> render_submit()

      assert view |> element("[data-testid=trigger-comment-pipemaestro]") |> render() =~
               "pipeline Correção de bug"

      assert length(Integrations.list_triggers(ctx.repo)) == 2
    end

    test "any author on new issues needs the confirmation", ctx do
      {:ok, view, _html} = live(ctx.conn, repo_path(ctx))
      view |> element("[data-testid=trigger-new]") |> render_click()

      view
      |> form("#trigger-form", trigger: %{kind: "opened", author_policy: "anyone"})
      |> render_change()

      assert has_element?(view, "[data-testid=trigger-confirm-anyone]")

      html =
        view
        |> form("#trigger-form", trigger: %{kind: "opened", author_policy: "anyone"})
        |> render_submit()

      assert html =~ "confirme"

      view
      |> form("#trigger-form",
        trigger: %{kind: "opened", author_policy: "anyone", confirm_anyone: "true"}
      )
      |> render_submit()

      assert has_element?(view, "[data-testid=trigger-opened]")
    end

    test "a direct task needs a pipeline; triggers can be turned off and removed", ctx do
      {:ok, view, _html} = live(ctx.conn, repo_path(ctx))
      view |> element("[data-testid=trigger-new]") |> render_click()

      html =
        view
        |> form("#trigger-form", trigger: %{kind: "label", label: "pm", mode: "task"})
        |> render_submit()

      assert html =~ "a tarefa direta precisa do pipeline"

      view
      |> form("#trigger-form",
        trigger: %{kind: "label", label: "pm", mode: "task", pipeline_id: ctx.pipeline.id}
      )
      |> render_submit()

      view |> element("[data-testid=trigger-edit-label-pm]") |> render_click()
      view |> form("#trigger-form", trigger: %{enabled: "false"}) |> render_submit()
      assert view |> element("[data-testid=trigger-label-pm]") |> render() =~ "desligado"

      view |> element("[data-testid=trigger-delete-label-pm]") |> render_click()
      refute has_element?(view, "[data-testid=trigger-label-pm]")
    end

    test "changes the project and unlinks", ctx do
      {:ok, view, _html} = live(ctx.conn, repo_path(ctx))
      view |> form("#repo-form", linked_repo: %{label_prefix: "pm"}) |> render_submit()
      assert "pm:pronto" in Enum.map(FakeForgejo.repo(ctx.fake, "acme/app").labels, & &1["name"])

      view |> element("[data-testid=repo-unlink]") |> render_click()
      assert_redirect(view, ipath(ctx, "/#{ctx.connection.id}"))
      assert Integrations.list_repos(ctx.connection) == []
    end
  end

  describe "deliveries" do
    setup ctx, do: %{connection: connection_fixture(ctx.workspace)}

    defp deliver(connection, id, payload) do
      {:ok, delivery} =
        Ingest.ingest_event(connection, id, "issues", payload)

      delivery
    end

    test "show up live, filter by status, open the payload and replay", ctx do
      {:ok, view, _html} = live(ctx.conn, ipath(ctx, "/#{ctx.connection.id}"))
      assert has_element?(view, "[data-testid=no-deliveries]")

      deliver(ctx.connection, "d-1", %{
        "action" => "opened",
        "repository" => %{"full_name" => "acme/nada", "project_id" => ctx.project.id},
        "issue" => %{"number" => 1, "labels" => []}
      })

      assert render(view) =~ "repositório não vinculado"
      assert view |> element("[data-testid=delivery-status-d-1]") |> render() =~ "ignorada"

      deliver(ctx.connection, "d-2", %{"action" => "milestoned"})
      view |> form("#deliveries-filter", deliveries: %{status: "processed"}) |> render_change()
      assert has_element?(view, "[data-testid=no-deliveries]")
      view |> form("#deliveries-filter", deliveries: %{status: "ignored"}) |> render_change()
      assert has_element?(view, "[data-testid=delivery-d-2]")

      view |> element("[data-testid=delivery-payload-toggle-d-1]") |> render_click()
      assert view |> element("[data-testid=delivery-payload-d-1]") |> render() =~ "acme/nada"

      view |> element("[data-testid=delivery-replay-d-1]") |> render_click()
      assert render_async(view) =~ "Reprocessada: ignorada"
    end
  end

  describe "repository sync" do
    test "reads the issues on demand", ctx do
      connection = connection_fixture(ctx.workspace)

      {:ok, repo} =
        Integrations.link_repo(
          connection,
          ctx.user,
          %{"full_name" => "acme/app", "project_id" => ctx.project.id},
          "https://x"
        )

      Integrations.save_trigger(repo, ctx.user, Integrations.new_trigger(repo, ctx.user), %{
        "kind" => "label",
        "label" => "pm"
      })

      FakeForgejo.put_issue(ctx.fake, "acme/app", %{
        "number" => 1,
        "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

      {:ok, view, _html} = live(ctx.conn, ipath(ctx, "/#{connection.id}/repos/#{repo.id}"))
      view |> element("[data-testid=repo-sync]") |> render_click()
      assert render_async(view) =~ "1 issue lida"
    end
  end
end
