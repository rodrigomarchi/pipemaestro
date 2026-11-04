defmodule PipeMaestro.AccountsTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.Accounts
  alias PipeMaestro.Accounts.{Scope, User, UserToken}

  describe "create_user/1" do
    test "stores a hash, never the password, and normalizes the e-mail" do
      {:ok, user} =
        Accounts.create_user(%{email: "  Ana@Acme.DEV ", name: "Ana", password: valid_password()})

      assert user.email == "ana@acme.dev"
      assert is_binary(user.hashed_password)
      assert is_nil(user.password)
    end

    test "requires a name, a valid e-mail and a long enough password" do
      {:error, changeset} = Accounts.create_user(%{email: "nope", password: "short"})

      assert %{name: [_], email: ["deve ser um e-mail válido"], password: [_]} =
               errors_on(changeset)
    end

    test "rejects an e-mail already in use, whatever its case" do
      user = user_fixture()

      {:error, changeset} =
        Accounts.create_user(%{
          email: String.upcase(user.email),
          name: "X",
          password: valid_password()
        })

      assert "já está em uso" in errors_on(changeset).email
    end
  end

  describe "get_user_by_email_and_password/2" do
    test "returns the user for the right credentials" do
      user = user_fixture()
      assert %User{id: id} = Accounts.get_user_by_email_and_password(user.email, valid_password())
      assert id == user.id
    end

    test "returns nil for a wrong password, an unknown e-mail or a disabled user" do
      user = user_fixture()
      refute Accounts.get_user_by_email_and_password(user.email, "senha errada demais")
      refute Accounts.get_user_by_email_and_password("ninguem@example.com", valid_password())

      {:ok, _} = Accounts.disable_user(user)
      refute Accounts.get_user_by_email_and_password(user.email, valid_password())
    end
  end

  describe "sessions" do
    setup do: %{user: user_fixture()}

    test "a generated token finds its user and stores only a hash", %{user: user} do
      token = Accounts.generate_user_session_token(user)

      assert Accounts.get_user_by_session_token(token).id == user.id
      refute Repo.get_by(UserToken, token: token)
    end

    test "a deleted token no longer finds the user", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      :ok = Accounts.delete_user_session_token(token)
      refute Accounts.get_user_by_session_token(token)
    end

    test "an expired token no longer finds the user", %{user: user} do
      token = Accounts.generate_user_session_token(user)

      expired =
        DateTime.add(DateTime.utc_now(:second), -Accounts.session_validity_in_days() - 1, :day)

      Repo.update_all(UserToken, set: [inserted_at: expired])

      refute Accounts.get_user_by_session_token(token)
    end

    test "resetting the password ends every session", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      {:ok, _user} = Accounts.reset_user_password(user, %{password: "outra senha bem longa"})

      refute Accounts.get_user_by_session_token(token)
      assert Accounts.get_user_by_email_and_password(user.email, "outra senha bem longa")
    end

    test "a short new password is rejected", %{user: user} do
      assert {:error, changeset} = Accounts.reset_user_password(user, %{password: "curta"})
      assert errors_on(changeset).password != []
    end

    test "disabling ends every session; enabling allows signing in again", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      {:ok, disabled} = Accounts.disable_user(user)

      assert disabled.disabled_at
      refute Accounts.get_user_by_session_token(token)

      {:ok, enabled} = Accounts.enable_user(disabled)
      refute enabled.disabled_at
      assert Accounts.get_user_by_email_and_password(user.email, valid_password())
    end
  end

  describe "listing" do
    test "list_users/0 and get_user!/1 preload workspaces by name" do
      workspace = workspace_fixture(%{name: "Zeta"})
      user = member_fixture(workspace)

      assert [%User{workspaces: [%{name: "Zeta"}]}] = Accounts.list_users()
      assert Accounts.get_user!(user.id).workspaces |> hd() |> Map.get(:id) == workspace.id
      assert Accounts.get_user_by_email(String.upcase(user.email)).id == user.id
    end

    test "form changesets" do
      assert %Ecto.Changeset{} = Accounts.change_user_registration(%User{})
      assert %Ecto.Changeset{} = Accounts.change_user_password(%User{})
    end
  end

  describe "Scope" do
    test "carries the user and, once set, the workspace" do
      user = user_fixture()
      workspace = workspace_fixture()

      assert Scope.for_user(nil) == nil
      assert %Scope{user: ^user, workspace: nil} = scope = Scope.for_user(user)
      assert %Scope{workspace: ^workspace} = Scope.put_workspace(scope, workspace)
    end
  end
end
