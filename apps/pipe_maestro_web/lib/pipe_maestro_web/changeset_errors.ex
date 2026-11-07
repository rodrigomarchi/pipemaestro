defmodule PipeMaestroWeb.ChangesetErrors do
  @moduledoc """
  A changeset's errors as one line a person reads: each error with where it
  is (`stages[2].prompt: can't be blank`), nested changesets included, and the
  message's values (`%{count}`) filled in.
  """

  @doc "The errors of `changeset`, separated by `; `."
  @spec to_text(Ecto.Changeset.t()) :: String.t()
  def to_text(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&interpolate/1)
    |> lines(nil)
    |> Enum.join("; ")
  end

  defp interpolate({message, opts}) do
    Regex.replace(~r/%\{(\w+)\}/, message, fn whole, key ->
      Enum.find_value(opts, whole, fn {name, value} ->
        if to_string(name) == key, do: to_string(value)
      end)
    end)
  end

  defp lines(errors, path) when is_map(errors) do
    errors
    |> Enum.sort_by(fn {field, _} -> to_string(field) end)
    |> Enum.flat_map(fn {field, value} -> lines(value, join(path, field)) end)
  end

  defp lines(errors, path) when is_list(errors) do
    if Enum.all?(errors, &is_binary/1) do
      Enum.map(errors, &"#{path}: #{&1}")
    else
      errors
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, index} -> lines(item, "#{path}[#{index}]") end)
    end
  end

  defp join(nil, field), do: to_string(field)
  defp join(path, field), do: "#{path}.#{field}"
end
