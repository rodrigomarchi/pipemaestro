defmodule PipeMaestro.Accounts.UserToken do
  @moduledoc "A workspace-app session. Only the token's hash is stored."
  use PipeMaestro.Schema

  import Ecto.Query

  alias PipeMaestro.Accounts.User
  alias PipeMaestro.Auth.Token

  @validity_in_days 14

  @type t :: %__MODULE__{}

  schema "users_tokens" do
    field :token, :binary
    belongs_to :user, User

    timestamps(updated_at: false)
  end

  @doc "How long a user session lasts."
  @spec validity_in_days() :: pos_integer()
  def validity_in_days, do: @validity_in_days

  @doc "A new session token for `user` and the record that stores its hash."
  @spec build_session_token(User.t()) :: {binary(), t()}
  def build_session_token(%User{id: user_id}) do
    {token, hashed} = Token.generate()
    {token, %__MODULE__{token: hashed, user_id: user_id}}
  end

  @doc "Query for the enabled user owning a valid, unexpired `token`."
  @spec verify_session_token_query(binary()) :: Ecto.Query.t()
  def verify_session_token_query(token) do
    from t in __MODULE__,
      join: u in assoc(t, :user),
      where: t.token == ^Token.hash(token),
      where: t.inserted_at > ago(@validity_in_days, "day"),
      where: is_nil(u.disabled_at),
      select: u
  end

  @doc "Query for the record of `token`."
  @spec by_token_query(binary()) :: Ecto.Query.t()
  def by_token_query(token), do: from(t in __MODULE__, where: t.token == ^Token.hash(token))

  @doc "Query for every session of `user`."
  @spec by_user_query(User.t()) :: Ecto.Query.t()
  def by_user_query(%User{id: id}), do: from(t in __MODULE__, where: t.user_id == ^id)
end
