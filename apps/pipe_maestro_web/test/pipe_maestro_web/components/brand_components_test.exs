defmodule PipeMaestroWeb.BrandComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestroWeb.BrandComponents
  alias PipeMaestroWeb.Layouts

  defp find(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp one!(html, selector) do
    node = find(html, selector)
    assert Enum.count(node) == 1, "expected one #{selector} in:\n#{html}"
    node
  end

  defp classes(node), do: node |> LazyHTML.attribute("class") |> List.first("") |> String.split()

  describe "logo_mark/1" do
    test "draws the symbol as an inline, titled SVG" do
      html = render_component(&BrandComponents.logo_mark/1, class: "size-8")

      svg = one!(html, "svg")
      assert "size-8" in classes(svg)
      assert LazyHTML.attribute(svg, "role") == ["img"]
      assert svg |> LazyHTML.query("title") |> LazyHTML.text() == "PipeMaestro"
      assert LazyHTML.attribute(svg, "viewBox") == ["0 0 32 32"]
    end

    test "passes extra attributes through to the SVG" do
      html = render_component(&BrandComponents.logo_mark/1, "data-testid": "some-mark")

      assert html |> one!("svg") |> LazyHTML.attribute("data-testid") == ["some-mark"]
    end

    test "is the product's own drawing: no text, raster or third-party name" do
      html = render_component(&BrandComponents.logo_mark/1, [])

      assert Enum.empty?(find(html, "svg text"))
      assert Enum.empty?(find(html, "svg image"))
      refute html =~ ~r/claude|anthropic/i
    end
  end

  describe "Layouts.brand/1" do
    test "links home with the symbol and the name" do
      html = render_component(&Layouts.brand/1, [])

      link = one!(html, ~s(a[data-testid="brand"]))
      assert LazyHTML.attribute(link, "href") == ["/"]
      assert link |> LazyHTML.query(~s(svg[data-testid="brand-mark"])) |> Enum.count() == 1
      assert LazyHTML.text(link) =~ "PipeMaestro"
    end

    test "no longer uses the generic musical note icon" do
      refute render_component(&Layouts.brand/1, []) =~ "hero-musical-note"
    end

    test "compact hides only the name when the sidebar collapses" do
      html = render_component(&Layouts.brand/1, compact: true)

      assert html |> one!(".pc-sidebar__brand") |> LazyHTML.text() =~ "PipeMaestro"
      refute "pc-sidebar__brand" in classes(one!(html, ~s(svg[data-testid="brand-mark"])))
      assert Enum.empty?(find(html, ~s(.pc-sidebar__brand svg)))
    end

    test "is not compact by default" do
      assert Enum.empty?(find(render_component(&Layouts.brand/1, []), ".pc-sidebar__brand"))
    end

    test "sizes the symbol by the size attribute" do
      sm = render_component(&Layouts.brand/1, size: "sm")
      md = render_component(&Layouts.brand/1, size: "md")

      assert "size-7" in classes(one!(sm, ~s(svg[data-testid="brand-mark"])))
      assert "size-8" in classes(one!(md, ~s(svg[data-testid="brand-mark"])))
    end
  end
end
