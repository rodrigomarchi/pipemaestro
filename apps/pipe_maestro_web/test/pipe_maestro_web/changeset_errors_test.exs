defmodule PipeMaestroWeb.ChangesetErrorsTest do
  use ExUnit.Case, async: true

  alias PipeMaestroWeb.ChangesetErrors

  defmodule Stage do
    use Ecto.Schema

    embedded_schema do
      field(:prompt, :string)
    end
  end

  defmodule Pipeline do
    use Ecto.Schema

    embedded_schema do
      field(:name, :string)
      embeds_many(:stages, Stage)
    end
  end

  defp stage(attrs),
    do:
      %Stage{}
      |> Ecto.Changeset.cast(attrs, [:prompt])
      |> Ecto.Changeset.validate_required(:prompt)

  test "each error says where it is, nested ones included, with its values filled in" do
    changeset =
      %Pipeline{}
      |> Ecto.Changeset.cast(%{"name" => "ab"}, [:name])
      |> Ecto.Changeset.validate_length(:name, min: 3)
      |> Ecto.Changeset.put_embed(:stages, [stage(%{"prompt" => "ok"}), stage(%{})])

    assert ChangesetErrors.to_text(changeset) ==
             "name: should be at least 3 character(s); stages[1].prompt: can't be blank"
  end
end
