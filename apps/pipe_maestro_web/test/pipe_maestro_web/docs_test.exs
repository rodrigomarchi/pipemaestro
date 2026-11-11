defmodule PipeMaestroWeb.DocsTest do
  use ExUnit.Case, async: true

  alias PipeMaestroWeb.Docs
  alias PipeMaestroWeb.Docs.Blocks

  test "every page belongs to its section and has content" do
    for section <- Docs.sections(), page <- section.pages do
      assert page.section == section.key
      assert page.blocks != []
      assert {:ok, ^page} = Docs.fetch(page.slug)
    end

    assert Docs.fetch("nada") == :error
  end

  test "slugs are unique" do
    slugs = Enum.map(Docs.pages(), & &1.slug)
    assert slugs == Enum.uniq(slugs)
  end

  test "neighbors/1 follows the reading order" do
    [first, second | _] = Docs.pages()
    assert Docs.neighbors(first) == {nil, second}
    assert Docs.neighbors(List.last(Docs.pages())) |> elem(1) == nil
  end

  test "a screenshot line splits the Markdown around it" do
    assert [{:html, intro}, {:shot, %{name: "board"}}, {:html, outro}] =
             Blocks.render("## Antes\n\ntexto\n\n{{tela:board}}\n\nDepois", "x")

    assert intro =~ ~s(<h2 id="antes">)
    assert outro =~ "<p>Depois</p>"
  end

  test "raw HTML in the Markdown is not rendered" do
    assert [{:html, html}] = Blocks.render("<script>alert(1)</script>", "x")
    refute html =~ "<script>"
  end

  test "an unknown screenshot fails" do
    assert_raise ArgumentError, ~r/unknown screenshot "nenhuma"/, fn ->
      Blocks.render("{{tela:nenhuma}}", "x")
    end
  end
end
