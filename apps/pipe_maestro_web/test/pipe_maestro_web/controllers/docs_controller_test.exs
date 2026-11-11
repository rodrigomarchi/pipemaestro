defmodule PipeMaestroWeb.DocsControllerTest do
  use PipeMaestroWeb.ConnCase, async: true

  alias PipeMaestroWeb.Docs

  defp document(conn, path),
    do: conn |> get(path) |> html_response(200) |> LazyHTML.from_document()

  defp testids(doc, selector),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute("data-testid")

  test "GET /docs lists every section and links every page", %{conn: conn} do
    doc = document(conn, ~p"/docs")

    for section <- Docs.sections() do
      assert testids(doc, ~s([data-testid="docs-section-#{section.key}"])) != []

      for page <- section.pages do
        assert [href] =
                 doc
                 |> LazyHTML.query(~s([data-testid="docs-card-#{page.slug}"]))
                 |> LazyHTML.attribute("href")

        assert href == "/docs/#{page.slug}"
      end
    end
  end

  test "every page renders with its title, the index marking it and its neighbours",
       %{conn: conn} do
    pages = Docs.pages()

    for {page, index} <- Enum.with_index(pages) do
      doc = document(conn, ~p"/docs/#{page.slug}")

      assert doc
             |> LazyHTML.query(~s([data-testid="docs-title"]))
             |> LazyHTML.text()
             |> String.trim() == page.title

      assert doc
             |> LazyHTML.query(~s([data-testid="docs-nav-#{page.slug}"]))
             |> LazyHTML.attribute("aria-current") == ["page"]

      assert testids(doc, ~s([data-testid="docs-previous"])) != [] == index > 0
      assert testids(doc, ~s([data-testid="docs-next"])) != [] == index < length(pages) - 1
    end
  end

  test "a page places its screenshots light and dark", %{conn: conn} do
    doc = document(conn, ~p"/docs/primeiros-passos")
    shot = LazyHTML.query(doc, ~s([data-testid="docs-shot-runners"]))

    assert shot |> LazyHTML.query(~s(img[src="/images/landing/runners.png"])) |> Enum.count() == 1

    assert shot |> LazyHTML.query(~s(img[src="/images/landing/runners-dark.png"])) |> Enum.count() ==
             1
  end

  test "every internal link of the documentation leads to a page, and to a heading of it",
       %{conn: conn} do
    docs = Map.new(Docs.pages(), &{&1.slug, document(conn, ~p"/docs/#{&1.slug}")})
    index = document(conn, ~p"/docs")

    for {slug, doc} <- docs,
        href <-
          doc |> LazyHTML.query(".docs-prose a[href^='/docs']") |> LazyHTML.attribute("href") do
      {target, fragment} =
        case href |> String.trim_leading("/docs") |> String.split("#", parts: 2) do
          ["", fragment] ->
            {index, fragment}

          ["/" <> page, fragment] ->
            {Map.fetch!(docs, page), fragment}

          ["/" <> page] ->
            {Map.get(docs, page) || flunk("#{slug} links #{href}, which does not exist"), nil}
        end

      if fragment,
        do:
          assert(
            LazyHTML.query(target, "##{fragment}") |> Enum.count() == 1,
            "#{slug} links #{href}, whose heading does not exist"
          )
    end
  end

  test "an unknown page is a 404", %{conn: conn} do
    assert conn |> get(~p"/docs/nada-aqui") |> html_response(404)
  end
end
