defmodule PipeMaestro.WorkspacesTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.Workspaces
  alias PipeMaestro.Workspaces.Workspace

  doctest Workspace

  describe "create_workspace/1 and update_workspace/2" do
    test "derives the slug from the name when none is given" do
      {:ok, workspace} = Workspaces.create_workspace(%{name: "Ação & Companhia"})
      assert workspace.slug == "acao-companhia"
    end

    test "validates the slug format and uniqueness" do
      workspace_fixture(%{slug: "acme"})

      assert {:error, changeset} = Workspaces.create_workspace(%{name: "A", slug: "Acme!"})
      assert "use letras minúsculas, números e hífens" in errors_on(changeset).slug

      assert {:error, changeset} = Workspaces.create_workspace(%{name: "Acme", slug: "acme"})
      assert "já está em uso" in errors_on(changeset).slug
    end

    test "renames and changes the slug" do
      workspace = workspace_fixture()
      {:ok, updated} = Workspaces.update_workspace(workspace, %{name: "Novo nome", slug: "novo"})

      assert %{name: "Novo nome", slug: "novo"} = updated
      assert Workspaces.get_workspace!(workspace.id).slug == "novo"
      assert %Ecto.Changeset{} = Workspaces.change_workspace(workspace)
    end
  end

  describe "retention policies" do
    test "default to no limit on files and 30 days of full agent events, then metadata" do
      workspace = workspace_fixture()

      assert Map.get(workspace, :job_files_retention_days, :missing) == nil
      assert Map.get(workspace, :job_files_quota_mib, :missing) == nil
      assert Map.get(workspace, :agent_events_retention_days) == 30
      assert Map.get(workspace, :agent_events_after_retention) == :metadata
    end

    test "are kept when valid" do
      workspace = workspace_fixture()

      {:ok, updated} =
        Workspaces.update_workspace(workspace, %{
          job_files_retention_days: 90,
          job_files_quota_mib: 1024,
          agent_events_retention_days: 7,
          agent_events_after_retention: "delete"
        })

      assert Map.take(Workspaces.get_workspace!(updated.id), [
               :job_files_retention_days,
               :job_files_quota_mib,
               :agent_events_retention_days,
               :agent_events_after_retention
             ]) == %{
               job_files_retention_days: 90,
               job_files_quota_mib: 1024,
               agent_events_retention_days: 7,
               agent_events_after_retention: :delete
             }

      {:ok, cleared} =
        Workspaces.update_workspace(updated, %{
          job_files_retention_days: nil,
          job_files_quota_mib: nil
        })

      assert Map.get(cleared, :job_files_retention_days) == nil
      assert Map.get(cleared, :job_files_quota_mib) == nil
    end

    test "refuse values out of range, with a message in Portuguese" do
      workspace = workspace_fixture()

      for {attrs, field, message} <- [
            {%{job_files_retention_days: 0}, :job_files_retention_days, "use de 1 a 3650 dias"},
            {%{job_files_retention_days: 3651}, :job_files_retention_days,
             "use de 1 a 3650 dias"},
            {%{job_files_quota_mib: 0}, :job_files_quota_mib, "use um número positivo"},
            {%{job_files_quota_mib: -5}, :job_files_quota_mib, "use um número positivo"},
            {%{agent_events_retention_days: 0}, :agent_events_retention_days,
             "use de 1 a 3650 dias"},
            {%{agent_events_retention_days: nil}, :agent_events_retention_days,
             "não pode ficar em branco"},
            {%{agent_events_after_retention: "keep"}, :agent_events_after_retention,
             "escolha manter só os metadados ou apagar"}
          ] do
        assert {:error, changeset} = Workspaces.update_workspace(workspace, attrs)
        assert message in Map.get(errors_on(changeset), field, []), inspect(attrs)
      end
    end
  end

  describe "membership" do
    setup do
      workspace = workspace_fixture()
      %{workspace: workspace, user: user_fixture(%{name: "Bia"})}
    end

    test "add, list, count and remove", %{workspace: workspace, user: user} do
      assert Workspaces.list_non_members(workspace) |> Enum.map(& &1.id) == [user.id]

      {:ok, _} = Workspaces.add_member(workspace, user)

      assert [%{id: id}] = Workspaces.list_members(workspace)
      assert id == user.id
      assert Workspaces.list_non_members(workspace) == []
      assert [%Workspace{member_count: 1}] = Workspaces.list_workspaces()
      assert [%Workspace{}] = Workspaces.list_workspaces_for_user(user)
      assert Workspaces.get_workspace_for_user(user, workspace.slug).id == workspace.id

      :ok = Workspaces.remove_member(workspace, user)

      assert Workspaces.list_members(workspace) == []
      refute Workspaces.get_workspace_for_user(user, workspace.slug)
    end

    test "a user cannot be added twice", %{workspace: workspace, user: user} do
      {:ok, _} = Workspaces.add_member(workspace, user)
      assert {:error, changeset} = Workspaces.add_member(workspace, user)
      assert "já faz parte deste workspace" in errors_on(changeset).workspace_id
    end

    test "a user can belong to several workspaces", %{workspace: workspace, user: user} do
      other = workspace_fixture()
      {:ok, _} = Workspaces.add_member(workspace, user)
      {:ok, _} = Workspaces.add_member(other, user)

      assert length(Workspaces.list_workspaces_for_user(user)) == 2
    end
  end

  describe "create_member/2" do
    test "creates the user inside the workspace" do
      workspace = workspace_fixture()

      {:ok, user} =
        Workspaces.create_member(workspace, %{
          email: unique_email(),
          name: "Caio",
          password: valid_password()
        })

      assert Workspaces.get_workspace_for_user(user, workspace.slug)
    end

    test "creates nothing when the user is invalid" do
      workspace = workspace_fixture()
      assert {:error, _changeset} = Workspaces.create_member(workspace, %{email: "bad"})
      assert Workspaces.list_members(workspace) == []
    end
  end
end
