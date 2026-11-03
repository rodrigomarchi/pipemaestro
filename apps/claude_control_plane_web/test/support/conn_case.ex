defmodule ClaudeControlPlaneWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ClaudeControlPlaneWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ClaudeControlPlaneWeb.Endpoint

      use ClaudeControlPlaneWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ClaudeControlPlane.Fixtures
      import ClaudeControlPlaneWeb.ConnCase
    end
  end

  setup tags do
    ClaudeControlPlane.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Signs `user` in on `conn`, the way the sign-in form would."
  @spec log_in_user(Plug.Conn.t(), ClaudeControlPlane.Accounts.User.t()) :: Plug.Conn.t()
  def log_in_user(conn, user) do
    token = ClaudeControlPlane.Accounts.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  @doc "Signs `operator` in to the backoffice on `conn`."
  @spec log_in_operator(Plug.Conn.t(), ClaudeControlPlane.Backoffice.Operator.t()) ::
          Plug.Conn.t()
  def log_in_operator(conn, operator) do
    token = ClaudeControlPlane.Backoffice.generate_operator_session_token(operator)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:operator_token, token)
  end

  @doc "Setup: a workspace, a member of it, and a conn signed in as that member."
  @spec register_and_log_in_member(map()) :: map()
  def register_and_log_in_member(%{conn: conn}) do
    workspace = ClaudeControlPlane.Fixtures.workspace_fixture(%{name: "Acme Engineering"})
    user = ClaudeControlPlane.Fixtures.member_fixture(workspace, %{name: "Ana Lima"})
    %{conn: log_in_user(conn, user), user: user, workspace: workspace}
  end

  @doc "Setup: an operator and a conn signed in to the backoffice as them."
  @spec register_and_log_in_operator(map()) :: map()
  def register_and_log_in_operator(%{conn: conn}) do
    operator = ClaudeControlPlane.Fixtures.operator_fixture(%{name: "Olga Operadora"})
    %{conn: log_in_operator(conn, operator), operator: operator}
  end
end
