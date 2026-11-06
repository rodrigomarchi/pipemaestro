defmodule PipeMaestro.Integrations.SchemasTest do
  use PipeMaestro.DataCase, async: true

  alias PipeMaestro.Integrations
  alias PipeMaestro.Integrations.{Connection, LinkedRepo, Trigger}

  describe "Connection.changeset/2" do
    test "takes a Forgejo connection by token, normalizing the URL and keeping the token encrypted" do
      changeset =
        Connection.changeset(%Connection{}, %{
          "name" => " Forgejo da casa ",
          "provider" => "forgejo",
          "base_url" => " https://git.exemplo.com/ ",
          "auth_kind" => "token",
          "token" => "tok_123"
        })

      assert changeset.valid?
      connection = Ecto.Changeset.apply_changes(changeset)
      assert connection.name == "Forgejo da casa"
      assert connection.base_url == "https://git.exemplo.com"
      assert connection.api_mode == "control_plane"
      assert Connection.credentials(connection) == %{"token" => "tok_123"}
      refute inspect(connection) =~ "tok_123"
    end

    test "requires the name, a known provider, an https URL and the token" do
      errors =
        %Connection{}
        |> Connection.changeset(%{
          "provider" => "gitlab",
          "base_url" => "ftp://x",
          "auth_kind" => "token"
        })
        |> errors_on()

      assert errors[:name]
      assert errors[:provider]
      assert errors[:base_url]
      assert errors[:token]
    end

    test "takes http only for a local host" do
      local = %{"name" => "a", "provider" => "forgejo", "auth_kind" => "token", "token" => "t"}

      assert Connection.changeset(
               %Connection{},
               Map.put(local, "base_url", "http://localhost:4013")
             ).valid?

      refute Connection.changeset(
               %Connection{},
               Map.put(local, "base_url", "http://git.exemplo.com")
             ).valid?
    end

    test "ties the authentication to the provider" do
      base = %{"name" => "a", "base_url" => "https://git.exemplo.com"}

      assert %{auth_kind: [_]} =
               errors_on(
                 Connection.changeset(
                   %Connection{},
                   Map.merge(base, %{"provider" => "forgejo", "auth_kind" => "github_app"})
                 )
               )

      assert %{auth_kind: [_]} =
               errors_on(
                 Connection.changeset(
                   %Connection{},
                   Map.merge(base, %{
                     "provider" => "github",
                     "auth_kind" => "token",
                     "token" => "t"
                   })
                 )
               )
    end

    test "an OAuth connection needs the client id and secret, not a token" do
      attrs = %{
        "name" => "a",
        "provider" => "forgejo",
        "base_url" => "https://git.exemplo.com",
        "auth_kind" => "oauth"
      }

      assert %{oauth_client_id: [_], oauth_client_secret: [_]} =
               errors_on(Connection.changeset(%Connection{}, attrs))

      changeset =
        Connection.changeset(
          %Connection{},
          Map.merge(attrs, %{"oauth_client_id" => "cid", "oauth_client_secret" => "csecret"})
        )

      assert changeset.valid?
      assert Connection.oauth_client_secret(Ecto.Changeset.apply_changes(changeset)) == "csecret"
    end

    test "editing keeps the stored token when none is typed" do
      {:ok, connection} =
        %Connection{}
        |> Connection.changeset(%{
          "name" => "a",
          "provider" => "forgejo",
          "base_url" => "https://git.exemplo.com",
          "auth_kind" => "token",
          "token" => "t1"
        })
        |> Ecto.Changeset.apply_action(:insert)

      changeset = Connection.changeset(connection, %{"name" => "b", "token" => ""})
      assert changeset.valid?
      assert Connection.credentials(Ecto.Changeset.apply_changes(changeset)) == %{"token" => "t1"}
    end
  end

  describe "LinkedRepo.changeset/2" do
    test "splits and downcases the full name" do
      changeset = LinkedRepo.changeset(%LinkedRepo{}, %{"full_name" => " Acme/App "})

      assert changeset.valid?
      repo = Ecto.Changeset.apply_changes(changeset)
      assert {repo.full_name, repo.owner, repo.name} == {"acme/app", "acme", "app"}
      assert repo.label_prefix == "pipemaestro"
    end

    test "refuses a name that is not owner/repository and a bad label prefix" do
      assert %{full_name: [_]} =
               errors_on(LinkedRepo.changeset(%LinkedRepo{}, %{"full_name" => "acme"}))

      assert %{label_prefix: [_]} =
               errors_on(
                 LinkedRepo.changeset(%LinkedRepo{}, %{
                   "full_name" => "a/b",
                   "label_prefix" => "Com espaço"
                 })
               )
    end
  end

  describe "Trigger.changeset/3" do
    test "a label trigger needs the label" do
      assert %{label: [_]} =
               errors_on(Trigger.changeset(%Trigger{}, %{"kind" => "label"}, "control_plane"))

      assert Trigger.changeset(
               %Trigger{},
               %{"kind" => "label", "label" => "pipemaestro"},
               "control_plane"
             ).valid?
    end

    test "a comment trigger needs a command that starts with a slash" do
      assert %{command: [_]} =
               errors_on(
                 Trigger.changeset(
                   %Trigger{},
                   %{"kind" => "comment", "command" => "pipemaestro"},
                   "control_plane"
                 )
               )

      assert Trigger.changeset(
               %Trigger{},
               %{"kind" => "comment", "command" => "/pipemaestro"},
               "control_plane"
             ).valid?
    end

    test "a direct task needs a pipeline; a triage may leave the choice to the agent" do
      assert %{pipeline_id: [_]} =
               errors_on(
                 Trigger.changeset(
                   %Trigger{},
                   %{"kind" => "opened", "mode" => "task"},
                   "control_plane"
                 )
               )

      assert Trigger.changeset(
               %Trigger{},
               %{"kind" => "opened", "mode" => "triage"},
               "control_plane"
             ).valid?
    end

    test "keeps the hourly limit between 1 and 100" do
      attrs = %{"kind" => "opened"}

      assert %{max_per_hour: [_]} =
               errors_on(
                 Trigger.changeset(%Trigger{}, Map.put(attrs, "max_per_hour", 0), "control_plane")
               )

      assert %{max_per_hour: [_]} =
               errors_on(
                 Trigger.changeset(
                   %Trigger{},
                   Map.put(attrs, "max_per_hour", 101),
                   "control_plane"
                 )
               )
    end

    test "with the runner calling the host, only a label triggers" do
      assert %{kind: [_]} =
               errors_on(
                 Trigger.changeset(
                   %Trigger{},
                   %{"kind" => "comment", "command" => "/pm"},
                   "runner"
                 )
               )

      assert %{kind: [_]} =
               errors_on(Trigger.changeset(%Trigger{}, %{"kind" => "opened"}, "runner"))

      assert Trigger.changeset(%Trigger{}, %{"kind" => "label", "label" => "pm"}, "runner").valid?
    end

    test "any author on a comment or a new issue must be confirmed" do
      attrs = %{"kind" => "opened", "author_policy" => "anyone"}

      assert %{confirm_anyone: [_]} =
               errors_on(Trigger.changeset(%Trigger{}, attrs, "control_plane"))

      assert Trigger.changeset(
               %Trigger{},
               Map.put(attrs, "confirm_anyone", "true"),
               "control_plane"
             ).valid?

      task =
        Map.merge(attrs, %{
          "confirm_anyone" => "true",
          "mode" => "task",
          "pipeline_id" => Ecto.UUID.generate()
        })

      assert %{mode: ["com qualquer autor, use a triagem com IA"]} =
               errors_on(Trigger.changeset(%Trigger{}, task, "control_plane"))

      label = %{"kind" => "label", "label" => "pm", "author_policy" => "anyone"}
      assert Trigger.changeset(%Trigger{}, label, "control_plane").valid?
    end
  end

  describe "issue URLs" do
    test "take an issue of any host and refuse a pull request" do
      assert "https://github.com/acme/app/issues/3" =~ Integrations.issue_url_regex()
      assert "https://git.exemplo.com/acme/app/issues/3" =~ Integrations.issue_url_regex()
      assert "http://localhost:4013/acme/app/issues/3" =~ Integrations.issue_url_regex()
      refute "https://git.exemplo.com/acme/app/pulls/3" =~ Integrations.issue_url_regex()
      refute "https://git.exemplo.com/acme/issues/3" =~ Integrations.issue_url_regex()
    end
  end
end
