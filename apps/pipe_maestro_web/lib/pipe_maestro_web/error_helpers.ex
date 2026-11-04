defmodule PipeMaestroWeb.ErrorHelpers do
  @moduledoc """
  Turns changeset errors into the messages forms display. petal_components
  calls `translate_error/1` for every field error (see `config/config.exs`).

  Ecto's built-in messages are in English; the ones the forms can produce are
  rendered in Portuguese here. Messages the app writes itself are already in
  Portuguese and pass through. Only `%{key}` bindings with a scalar value are
  interpolated: Ecto also attaches lists (such as `fields: [:slug]`) that are
  not meant for display.
  """

  @messages %{
    "can't be blank" => "não pode ficar em branco",
    "has already been taken" => "já está em uso",
    "is invalid" => "é inválido",
    "has invalid format" => "tem formato inválido",
    "should be at least %{count} character(s)" => "deve ter pelo menos %{count} caracteres",
    "should be at most %{count} character(s)" => "deve ter no máximo %{count} caracteres",
    "does not exist" => "não existe"
  }

  @doc "The display message for one changeset error."
  @spec translate_error({String.t(), keyword()}) :: String.t()
  def translate_error({message, bindings}) do
    @messages
    |> Map.get(message, message)
    |> interpolate(bindings)
  end

  defp interpolate(message, bindings) do
    Enum.reduce(bindings, message, fn
      {key, value}, acc when is_binary(value) or is_number(value) or is_atom(value) ->
        String.replace(acc, "%{#{key}}", to_string(value))

      _list_or_struct, acc ->
        acc
    end)
  end
end
