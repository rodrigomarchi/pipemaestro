defmodule PipeMaestro.AuthorizationTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.Accounts.Scope
  alias PipeMaestro.{Authorization, Workspaces}
  alias PipeMaestro.Tasks.Task

  test "the first member is an admin, the next ones members; roles can change" do
    workspace = workspace_fixture()
    first = member_fixture(workspace)
    second = member_fixture(workspace)

    assert Workspaces.role(workspace, first) == :admin
    assert Workspaces.role(workspace, second) == :member
    assert Workspaces.role(workspace, user_fixture()) == nil

    assert :ok = Workspaces.set_role(workspace, second, :admin)
    assert Workspaces.role(workspace, second) == :admin
    assert {:error, :not_member} = Workspaces.set_role(workspace, user_fixture(), :admin)

    assert [%{role: :admin}, %{role: :admin}] = Workspaces.list_memberships(workspace)

    other = workspace_fixture()
    {:ok, _} = Workspaces.add_member(other, second, :member)
    assert [%{id: id}] = Workspaces.list_workspaces_for_user(second, role: :admin)
    assert id == workspace.id
    assert length(Workspaces.list_workspaces_for_user(second)) == 2
  end

  test "admins manage pipelines, projects and runners; anyone runs and decides tasks" do
    workspace = workspace_fixture()
    admin = member_fixture(workspace)
    member = member_fixture(workspace)

    as = fn user ->
      %Scope{user: user, workspace: workspace, role: Workspaces.role(workspace, user)}
    end

    for action <- [:manage_pipelines, :manage_projects, :manage_runners, :manage_integrations] do
      assert Authorization.can?(as.(admin), action)
      refute Authorization.can?(as.(member), action)
    end

    own = %Task{created_by_user_id: member.id}
    others = %Task{created_by_user_id: admin.id}

    assert Authorization.can?(as.(member), :cancel_task, own)
    refute Authorization.can?(as.(member), :cancel_task, others)
    assert Authorization.can?(as.(admin), :cancel_task, own)
    assert Authorization.can?(as.(member), :run_tasks)
  end
end
