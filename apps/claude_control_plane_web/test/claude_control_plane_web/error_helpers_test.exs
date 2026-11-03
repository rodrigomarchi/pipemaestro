defmodule ClaudeControlPlaneWeb.ErrorHelpersTest do
  use ExUnit.Case, async: true

  alias ClaudeControlPlaneWeb.ErrorHelpers

  test "translates Ecto's messages and interpolates counts" do
    assert ErrorHelpers.translate_error({"can't be blank", [validation: :required]}) ==
             "não pode ficar em branco"

    assert ErrorHelpers.translate_error(
             {"should be at least %{count} character(s)", [count: 12, validation: :length]}
           ) == "deve ter pelo menos 12 caracteres"
  end

  test "passes the app's own messages through and ignores list bindings" do
    assert ErrorHelpers.translate_error(
             {"já está em uso", [validation: :unsafe_unique, fields: [:slug]]}
           ) == "já está em uso"
  end
end
