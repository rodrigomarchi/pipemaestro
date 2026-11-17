defmodule PipeMaestro.OnboardingTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.Accounts.Scope
  alias PipeMaestro.{Onboarding, Workspaces}

  defp owned_scope do
    user = user_fixture()
    {:ok, workspace} = Workspaces.create_owned_workspace(user, %{"name" => "Acme"})
    scope_for(user, workspace)
  end

  defp scope_for(user, workspace) do
    user |> Scope.for_user() |> Scope.put_workspace(workspace, Workspaces.role(workspace, user))
  end

  defp configure(%Scope{user: user, workspace: workspace}, parts) do
    {runner, _token} = runner_fixture(workspace, user)
    runner = with_directories(runner, [%{"name" => "app", "git" => true}])
    if :project in parts, do: project_fixture(runner, "app")
    if :pipeline in parts, do: pipeline_fixture(workspace)
    :ok
  end

  describe "pending?/1" do
    test "for the admin of a new Free beta workspace" do
      assert Onboarding.pending?(owned_scope())
    end

    test "while a runner, a project or a pipeline is missing" do
      scope = owned_scope()
      :ok = configure(scope, [:project])
      assert Onboarding.pending?(scope)
    end

    test "not once the workspace has a runner, a project and a pipeline" do
      scope = owned_scope()
      :ok = configure(scope, [:project, :pipeline])
      refute Onboarding.pending?(scope)
    end

    test "not for a member who is not an admin" do
      %Scope{workspace: workspace} = owned_scope()
      member = member_fixture(workspace)
      refute Onboarding.pending?(scope_for(member, workspace))
    end

    test "not in a workspace an operator created" do
      workspace = workspace_fixture()
      admin = member_fixture(workspace)
      refute Onboarding.pending?(scope_for(admin, workspace))
    end
  end

  describe "dismiss/1" do
    test "ends the lesson for good, and may be called again" do
      scope = owned_scope()

      assert :ok = Onboarding.dismiss(scope)
      refute Onboarding.pending?(scope)
      assert :ok = Onboarding.dismiss(scope)
    end

    test "ends it only for that person" do
      %Scope{workspace: workspace} = scope = owned_scope()
      other_admin = member_fixture(workspace, %{}, :admin)

      :ok = Onboarding.dismiss(scope)
      assert Onboarding.pending?(scope_for(other_admin, workspace))
    end
  end
end
