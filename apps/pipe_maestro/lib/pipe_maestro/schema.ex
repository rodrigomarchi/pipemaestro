defmodule PipeMaestro.Schema do
  @moduledoc """
  Defaults shared by every schema: UUID primary and foreign keys, so tenant
  data is never addressable by a guessable sequence, and UTC timestamps.
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime]
    end
  end
end
