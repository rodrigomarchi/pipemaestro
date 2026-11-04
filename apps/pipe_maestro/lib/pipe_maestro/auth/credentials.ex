defmodule PipeMaestro.Auth.Credentials do
  @moduledoc """
  E-mail and password rules shared by users and operators.

  Both identities sign in with an e-mail and a password; the rules (format,
  length, hashing, constant-time verification) live here once.
  """

  import Ecto.Changeset

  @typedoc "Any record that signs in with a password: a user or an operator."
  @type credentialed :: %{
          required(:hashed_password) => String.t() | nil,
          optional(atom()) => any()
        }

  @min_password_length 6
  @max_password_length 72

  @doc "The shortest password accepted."
  @spec min_password_length() :: pos_integer()
  def min_password_length, do: @min_password_length

  @doc "Validates `:email` and its uniqueness against `unique_index`."
  @spec validate_email(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_email(changeset, unique_index) do
    changeset
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+\.[^@,;\s]+$/,
      message: "deve ser um e-mail válido"
    )
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, PipeMaestro.Repo, message: "já está em uso")
    |> unique_constraint(:email, name: unique_index, message: "já está em uso")
  end

  @doc """
  Validates `:password` and, when the changeset is valid, replaces it with
  `:hashed_password`.
  """
  @spec validate_and_hash_password(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_and_hash_password(changeset) do
    changeset =
      changeset
      |> validate_required([:password])
      |> validate_length(:password,
        min: @min_password_length,
        max: @max_password_length,
        count: :bytes,
        message: "deve ter entre #{@min_password_length} e #{@max_password_length} caracteres"
      )

    password = get_change(changeset, :password)

    if changeset.valid? and password do
      changeset
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Checks `password` against the stored hash. Runs a dummy verification when
  there is no record, so a missing account takes as long as a wrong password.
  """
  @spec valid_password?(credentialed() | nil, String.t()) :: boolean()
  def valid_password?(%{hashed_password: hashed}, password)
      when is_binary(hashed) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed)
  end

  def valid_password?(_record, _password) do
    Bcrypt.no_user_verify()
    false
  end

  @doc "Lowercases and trims an e-mail."
  @spec normalize_email(String.t() | nil) :: String.t() | nil
  def normalize_email(nil), do: nil
  def normalize_email(email), do: email |> String.trim() |> String.downcase()
end
