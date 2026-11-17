defmodule PipeMaestro.Workspaces.OwnedConcurrencyTest do
  # Real transactions on their own connections, outside the sandbox: only then
  # do concurrent creations race for the owner's lock.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PipeMaestro.{Accounts, Repo, Workspaces}
  alias PipeMaestro.Workspaces.{Plan, Workspace}

  import Ecto.Query

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        name: "Concorrente",
        email: "concorrente#{n}@example.com",
        password: "uma senha bem longa"
      })

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      Repo.delete_all(from w in Workspace, where: w.owner_id == ^user.id)
      Repo.delete!(user)
    end)

    %{user: user, n: n}
  end

  test "creations at once never pass the plan's limit", %{user: user, n: n} do
    results =
      1..6
      |> Enum.map(fn i ->
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)
          Workspaces.create_owned_workspace(user, %{"name" => "Corrida #{n} #{i}"})
        end)
      end)
      |> Task.await_many(10_000)

    limit = Plan.free_beta().workspaces_per_owner
    assert Enum.count(results, &match?({:ok, _}, &1)) == limit
    assert Enum.count(results, &(&1 == {:error, :limit_reached})) == 6 - limit
    assert Workspaces.count_owned_workspaces(user) == limit
  end
end
