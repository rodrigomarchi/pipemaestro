defmodule PipeMaestro.Backoffice.OperatorToken do
  @moduledoc "A backoffice session. Only the token's hash is stored."
  use PipeMaestro.Schema

  import Ecto.Query

  alias PipeMaestro.Auth.Token
  alias PipeMaestro.Backoffice.Operator

  @validity_in_hours 12

  @type t :: %__MODULE__{}

  schema "operators_tokens" do
    field :token, :binary
    belongs_to :operator, Operator

    timestamps(updated_at: false)
  end

  @doc "How long a backoffice session lasts."
  @spec validity_in_hours() :: pos_integer()
  def validity_in_hours, do: @validity_in_hours

  @doc "A new session token for `operator` and the record that stores its hash."
  @spec build_session_token(Operator.t()) :: {binary(), t()}
  def build_session_token(%Operator{id: operator_id}) do
    {token, hashed} = Token.generate()
    {token, %__MODULE__{token: hashed, operator_id: operator_id}}
  end

  @doc "Query for the enabled operator owning a valid, unexpired `token`."
  @spec verify_session_token_query(binary()) :: Ecto.Query.t()
  def verify_session_token_query(token) do
    from t in __MODULE__,
      join: o in assoc(t, :operator),
      where: t.token == ^Token.hash(token),
      where: t.inserted_at > ago(@validity_in_hours, "hour"),
      where: is_nil(o.disabled_at),
      select: o
  end

  @doc "Query for the record of `token`."
  @spec by_token_query(binary()) :: Ecto.Query.t()
  def by_token_query(token), do: from(t in __MODULE__, where: t.token == ^Token.hash(token))

  @doc "Query for every session of `operator`."
  @spec by_operator_query(Operator.t()) :: Ecto.Query.t()
  def by_operator_query(%Operator{id: id}), do: from(t in __MODULE__, where: t.operator_id == ^id)
end
