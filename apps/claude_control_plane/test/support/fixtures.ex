defmodule ClaudeControlPlane.Fixtures do
  @moduledoc "Records for tests: users, operators and workspaces with valid defaults."

  alias ClaudeControlPlane.{Accounts, Backoffice, Workspaces}

  @doc "A password that passes every rule."
  @spec valid_password() :: String.t()
  def valid_password, do: "uma senha bem longa"

  @doc "A unique e-mail."
  @spec unique_email() :: String.t()
  def unique_email, do: "pessoa#{System.unique_integer([:positive])}@example.com"

  @doc "A created user."
  @spec user_fixture(map()) :: Accounts.User.t()
  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{email: unique_email(), name: "Pessoa Teste", password: valid_password()})
      |> Accounts.create_user()

    user
  end

  @doc "A created operator."
  @spec operator_fixture(map()) :: Backoffice.Operator.t()
  def operator_fixture(attrs \\ %{}) do
    {:ok, operator} =
      attrs
      |> Enum.into(%{email: unique_email(), name: "Operador Teste", password: valid_password()})
      |> Backoffice.create_operator()

    operator
  end

  @doc "A created workspace."
  @spec workspace_fixture(map()) :: Workspaces.Workspace.t()
  def workspace_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, workspace} =
      attrs
      |> Enum.into(%{name: "Empresa #{n}", slug: "empresa-#{n}"})
      |> Workspaces.create_workspace()

    workspace
  end

  @doc "A user who belongs to `workspace`."
  @spec member_fixture(Workspaces.Workspace.t(), map()) :: Accounts.User.t()
  def member_fixture(workspace, attrs \\ %{}) do
    user = user_fixture(attrs)
    {:ok, _membership} = Workspaces.add_member(workspace, user)
    user
  end
end
