defmodule ClaudeControlPlane.Backoffice do
  @moduledoc """
  Platform operators: the people who run the backoffice, create workspaces and
  manage users. Operators are a separate identity from workspace users, with
  their own table, sessions and sign-in.
  """

  import Ecto.Query

  alias ClaudeControlPlane.Auth.Credentials
  alias ClaudeControlPlane.Backoffice.{Operator, OperatorToken}
  alias ClaudeControlPlane.Repo

  @doc "Every operator, by name."
  @spec list_operators() :: [Operator.t()]
  def list_operators, do: Repo.all(from o in Operator, order_by: [asc: o.name])

  @doc "The operator with `id`. Raises when there is none."
  @spec get_operator!(Ecto.UUID.t()) :: Operator.t()
  def get_operator!(id), do: Repo.get!(Operator, id)

  @doc """
  The enabled operator with `email` and `password`, or `nil`. A disabled
  operator, an unknown e-mail and a wrong password are indistinguishable.
  """
  @spec get_operator_by_email_and_password(String.t(), String.t()) :: Operator.t() | nil
  def get_operator_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    operator =
      Repo.one(
        from o in Operator,
          where: o.email == ^Credentials.normalize_email(email) and is_nil(o.disabled_at)
      )

    if Credentials.valid_password?(operator, password), do: operator
  end

  @doc "Creates an operator."
  @spec create_operator(map()) :: {:ok, Operator.t()} | {:error, Ecto.Changeset.t()}
  def create_operator(attrs) do
    %Operator{} |> Operator.registration_changeset(attrs) |> Repo.insert()
  end

  @doc "A changeset for the new-operator form."
  @spec change_operator_registration(Operator.t(), map()) :: Ecto.Changeset.t()
  def change_operator_registration(%Operator{} = operator, attrs \\ %{}) do
    Operator.registration_changeset(operator, attrs)
  end

  @doc "Disables an operator and ends all of their sessions."
  @spec disable_operator(Operator.t()) :: {:ok, Operator.t()} | {:error, Ecto.Changeset.t()}
  def disable_operator(%Operator{} = operator) do
    Repo.transact(fn ->
      with {:ok, operator} <- Repo.update(Operator.disabled_changeset(operator, true)) do
        Repo.delete_all(OperatorToken.by_operator_query(operator))
        {:ok, operator}
      end
    end)
  end

  @doc "Re-enables a disabled operator."
  @spec enable_operator(Operator.t()) :: {:ok, Operator.t()} | {:error, Ecto.Changeset.t()}
  def enable_operator(%Operator{} = operator) do
    Repo.update(Operator.disabled_changeset(operator, false))
  end

  @doc "Starts a backoffice session and returns its token."
  @spec generate_operator_session_token(Operator.t()) :: binary()
  def generate_operator_session_token(%Operator{} = operator) do
    {token, record} = OperatorToken.build_session_token(operator)
    Repo.insert!(record)
    token
  end

  @doc "The enabled operator of a valid session `token`, or `nil`."
  @spec get_operator_by_session_token(binary()) :: Operator.t() | nil
  def get_operator_by_session_token(token) do
    Repo.one(OperatorToken.verify_session_token_query(token))
  end

  @doc "Ends the session of `token`."
  @spec delete_operator_session_token(binary()) :: :ok
  def delete_operator_session_token(token) do
    Repo.delete_all(OperatorToken.by_token_query(token))
    :ok
  end

  @doc "How long a backoffice session lasts, in hours."
  @spec session_validity_in_hours() :: pos_integer()
  def session_validity_in_hours, do: OperatorToken.validity_in_hours()
end
