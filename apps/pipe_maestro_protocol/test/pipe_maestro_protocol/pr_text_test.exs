defmodule PipeMaestroProtocol.PrTextTest do
  use ExUnit.Case, async: true

  alias PipeMaestroProtocol.PrText

  test "wraps the platform's block between its markers" do
    assert PrText.wrap("  bloco \n") ==
             "<!-- pipemaestro:inicio -->\nbloco\n<!-- pipemaestro:fim -->"
  end

  test "replaces only the platform's block, or adds it at the end" do
    body = "Antes\n\n" <> PrText.wrap("velho") <> "\n\nDepois"
    assert PrText.body(body, "novo") == "Antes\n\n" <> PrText.wrap("novo") <> "\n\nDepois"

    assert PrText.body("Escrito por alguém", "novo") ==
             "Escrito por alguém\n\n" <> PrText.wrap("novo")

    assert PrText.body(nil, "novo") == PrText.wrap("novo")

    assert PrText.body("x <!-- pipemaestro:inicio --> sem fim", "novo") ==
             "x " <> PrText.wrap("novo")
  end

  test "adds or takes off the draft prefix, keeping the title" do
    assert PrText.title("Corrige login", true, "WIP: ") == "WIP: Corrige login"
    assert PrText.title("WIP: Corrige login", false, "WIP: ") == "Corrige login"
    assert PrText.title("WIP: Corrige login", true, "WIP: ") == "WIP: Corrige login"
  end
end
