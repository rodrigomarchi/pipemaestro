defmodule ClaudeControlPlane.BackofficeTest do
  use ClaudeControlPlane.DataCase, async: true

  import ClaudeControlPlane.Fixtures

  alias ClaudeControlPlane.Backoffice
  alias ClaudeControlPlane.Backoffice.{Operator, OperatorToken}

  test "create_operator/1 validates and hashes" do
    assert {:error, changeset} = Backoffice.create_operator(%{email: "x", password: "y"})
    assert %{name: [_], email: [_], password: [_]} = errors_on(changeset)

    operator = operator_fixture(%{email: "Ops@Example.com"})
    assert operator.email == "ops@example.com"
    assert [%Operator{}] = Backoffice.list_operators()
    assert Backoffice.get_operator!(operator.id).id == operator.id
    assert %Ecto.Changeset{} = Backoffice.change_operator_registration(%Operator{})
  end

  test "sign-in rejects wrong passwords and disabled operators" do
    operator = operator_fixture()

    assert Backoffice.get_operator_by_email_and_password(operator.email, valid_password())
    refute Backoffice.get_operator_by_email_and_password(operator.email, "senha errada demais")

    {:ok, _} = Backoffice.disable_operator(operator)
    refute Backoffice.get_operator_by_email_and_password(operator.email, valid_password())
  end

  test "sessions expire after the backoffice validity" do
    operator = operator_fixture()
    token = Backoffice.generate_operator_session_token(operator)
    assert Backoffice.get_operator_by_session_token(token).id == operator.id

    expired =
      DateTime.add(DateTime.utc_now(:second), -Backoffice.session_validity_in_hours() - 1, :hour)

    Repo.update_all(OperatorToken, set: [inserted_at: expired])
    refute Backoffice.get_operator_by_session_token(token)
  end

  test "logging out and disabling end sessions; enabling restores sign-in" do
    operator = operator_fixture()
    first = Backoffice.generate_operator_session_token(operator)
    second = Backoffice.generate_operator_session_token(operator)

    :ok = Backoffice.delete_operator_session_token(first)
    refute Backoffice.get_operator_by_session_token(first)
    assert Backoffice.get_operator_by_session_token(second)

    {:ok, disabled} = Backoffice.disable_operator(operator)
    refute Backoffice.get_operator_by_session_token(second)

    {:ok, _} = Backoffice.enable_operator(disabled)
    assert Backoffice.get_operator_by_email_and_password(operator.email, valid_password())
  end
end
