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

  defp has_class?(node, class), do: class in classes(node)

  defp number(node, attr) do
    {value, _} = node |> LazyHTML.attribute(attr) |> List.first("0") |> Float.parse()
    value
  end

  defp center(node), do: {number(node, "cx"), number(node, "cy")}

  defp translucent?(node) do
    Enum.any?(
      ~w(opacity stroke-opacity),
      &(LazyHTML.attribute(node, &1) != [] and number(node, &1) < 1)
    ) or
      Enum.any?(classes(node), &(&1 =~ ~r{^opacity-\d|^stroke-[a-z]+-\d+/\d+$}))
  end

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

    test "shares no element ids, definitions or animation between symbols on one page" do
      html = render_component(&BrandComponents.logo_mark/1, [])

      assert Enum.empty?(find(html, "svg [id]"))

      for tag <- ~w(defs filter linearGradient radialGradient animate animateTransform) do
        refute html =~ "<#{tag}", "inline symbol must not carry <#{tag}>"
      end

      refute html =~ "animate-"
    end

    test "sits on a dark square that stands out from a dark sidebar" do
      svg = one!(render_component(&BrandComponents.logo_mark/1, []), "svg")
      svg_classes = classes(svg)

      assert "bg-gradient-to-br" in svg_classes
      assert "from-primary-950" in svg_classes
      assert "to-secondary-950" in svg_classes
      assert Enum.any?(svg_classes, &String.starts_with?(&1, "ring-"))
      assert Enum.any?(svg_classes, &(&1 =~ ~r/shadow.*primary/))
    end

    test "draws in neon violet and cyan, not in the text color" do
      html = render_component(&BrandComponents.logo_mark/1, [])

      refute html =~ "currentColor"
      refute "text-white" in classes(one!(html, "svg"))
      refute Enum.empty?(find(html, "svg .stroke-primary-400"))
      refute Enum.empty?(find(html, "svg circle.fill-secondary-400"))
      refute Enum.empty?(find(html, "svg circle.stroke-secondary-400"))
    end

    test "traces run as circuit lines, with no curves" do
      html = render_component(&BrandComponents.logo_mark/1, [])

      paths = html |> find("svg path") |> LazyHTML.attribute("d")
      refute paths == []
      for d <- paths, do: refute(d =~ ~r/[CcSsQqTtAa]/, "curved path: #{d}")
    end

    test "glows through a wider, translucent copy of the traces" do
      html = render_component(&BrandComponents.logo_mark/1, [])

      assert html |> find("svg *") |> Enum.any?(&translucent?/1)
    end

    test "keeps the meaning: three agent pads, one stage ring and the pull request dot" do
      html = render_component(&BrandComponents.logo_mark/1, [])

      pads = html |> find("svg circle.stroke-primary-400") |> Enum.map(&center/1)
      assert [{pad_x, _} | _] = pads

      assert pads
             |> Enum.filter(&(elem(&1, 0) == pad_x))
             |> Enum.map(&elem(&1, 1))
             |> Enum.uniq()
             |> length() == 3

      [ring | _] =
        html
        |> find("svg circle.stroke-secondary-400")
        |> Enum.reject(&has_class?(&1, "fill-secondary-400"))
        |> Enum.to_list()

      [dot | _] = html |> find("svg circle.fill-secondary-400") |> Enum.to_list()

      {ring_x, _} = center(ring)
      {dot_x, _} = center(dot)
      assert pad_x < ring_x and ring_x < dot_x
      assert number(dot, "r") > number(ring, "r")
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

    test "testid names the link and its symbol" do
      html = render_component(&Layouts.brand/1, testid: "footer-brand")

      link = one!(html, ~s(a[data-testid="footer-brand"]))
      assert link |> LazyHTML.query(~s(svg[data-testid="footer-brand-mark"])) |> Enum.count() == 1
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
