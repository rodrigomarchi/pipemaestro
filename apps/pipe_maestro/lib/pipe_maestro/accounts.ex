defmodule PipeMaestro.Accounts do
  @moduledoc """
  Workspace users: people who sign in to the product with an e-mail and a
  password. Users are created by operators; there is no self sign-up.
  """

  import Ecto.Query

  alias PipeMaestro.Accounts.{User, UserToken}
  alias PipeMaestro.Auth.Credentials
  alias PipeMaestro.Repo
  alias PipeMaestro.Workspaces.Workspace

  @doc "Every user, by name, with their workspaces loaded."
  @spec list_users() :: [User.t()]
  def list_users do
    Repo.all(
      from u in User, order_by: [asc: u.name], preload: [workspaces: ^workspaces_by_name()]
    )
  end

  @doc "The user with `id`, workspaces loaded. Raises when there is none."
  @spec get_user!(Ecto.UUID.t()) :: User.t()
  def get_user!(id) do
    User |> Repo.get!(id) |> Repo.preload(workspaces: workspaces_by_name())
  end

  @doc "The user with `email`, or `nil`."
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: Credentials.normalize_email(email))
  end

  @doc """
  The enabled user with `email` and `password`, or `nil`. A disabled user, an
  unknown e-mail and a wrong password are indistinguishable.
  """
  @spec get_user_by_email_and_password(String.t(), String.t()) :: User.t() | nil
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user =
      Repo.one(
        from u in User,
          where: u.email == ^Credentials.normalize_email(email) and is_nil(u.disabled_at)
      )

    if Credentials.valid_password?(user, password), do: user
  end

  @doc "Creates a user."
  @spec create_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_user(attrs) do
    %User{} |> User.registration_changeset(attrs) |> Repo.insert()
  end

  @doc "A changeset for the new-user form."
  @spec change_user_registration(User.t(), map()) :: Ecto.Changeset.t()
  def change_user_registration(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs)
  end

  @doc "A changeset for the reset-password form."
  @spec change_user_password(User.t(), map()) :: Ecto.Changeset.t()
  def change_user_password(%User{} = user, attrs \\ %{}) do
    User.password_changeset(user, attrs)
  end

  @doc "Sets a new password and ends all of the user's sessions."
  @spec reset_user_password(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def reset_user_password(%User{} = user, attrs) do
    update_and_end_sessions(User.password_changeset(user, attrs))
  end

  @doc "Disables a user and ends all of their sessions."
  @spec disable_user(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def disable_user(%User{} = user) do
    update_and_end_sessions(User.disabled_changeset(user, true))
  end

  @doc "Re-enables a disabled user."
  @spec enable_user(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def enable_user(%User{} = user), do: Repo.update(User.disabled_changeset(user, false))

  @doc "Starts a session and returns its token."
  @spec generate_user_session_token(User.t()) :: binary()
  def generate_user_session_token(%User{} = user) do
    {token, record} = UserToken.build_session_token(user)
    Repo.insert!(record)
    token
  end

  @doc "The enabled user of a valid session `token`, or `nil`."
  @spec get_user_by_session_token(binary()) :: User.t() | nil
  def get_user_by_session_token(token), do: Repo.one(UserToken.verify_session_token_query(token))

  @doc "Ends the session of `token`."
  @spec delete_user_session_token(binary()) :: :ok
  def delete_user_session_token(token) do
    Repo.delete_all(UserToken.by_token_query(token))
    :ok
  end

  @doc "How long a user session lasts, in days."
  @spec session_validity_in_days() :: pos_integer()
  def session_validity_in_days, do: UserToken.validity_in_days()

  defp update_and_end_sessions(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        Repo.delete_all(UserToken.by_user_query(user))
        {:ok, user}
      end
    end)
  end

  defp workspaces_by_name do
    from w in Workspace, order_by: [asc: w.name]
  end
end
