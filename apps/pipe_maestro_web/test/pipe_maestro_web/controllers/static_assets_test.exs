defmodule PipeMaestroWeb.StaticAssetsTest do
  use PipeMaestroWeb.ConnCase, async: true

  @svgs ~w(logo-mark.svg logo-mark-mono.svg favicon.svg)

  defp svg_path(name), do: Application.app_dir(:pipe_maestro_web, "priv/static/images/#{name}")

  for name <- @svgs do
    test "GET /images/#{name} serves the SVG", %{conn: conn} do
      conn = get(conn, "/images/#{unquote(name)}")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "image/svg+xml"
    end

    test "#{name} is a square, titled, vector-only drawing with no third-party name" do
      svg = File.read!(svg_path(unquote(name)))

      assert svg =~ ~s(viewBox="0 0 32 32")
      assert svg =~ "<title>PipeMaestro</title>"
      refute svg =~ "<image"
      refute svg =~ "<text"
      refute svg =~ "@font-face"
      refute svg =~ ~r/claude|anthropic/i
    end
  end

  test "the mono symbol follows the text color", %{conn: _conn} do
    assert File.read!(svg_path("logo-mark-mono.svg")) =~ "currentColor"
  end

  test "pages declare the SVG favicon with the .ico as fallback", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    head = html |> LazyHTML.from_document() |> LazyHTML.query("head")

    svg_icon = LazyHTML.query(head, ~s(link[rel="icon"][type="image/svg+xml"]))
    assert [href] = LazyHTML.attribute(svg_icon, "href")
    assert href =~ ~r{^/images/favicon(-[0-9a-f]+)?\.svg}

    ico = LazyHTML.query(head, ~s(link[rel="icon"][sizes="any"]))
    assert [ico_href] = LazyHTML.attribute(ico, "href")
    assert ico_href =~ ~r{^/favicon(-[0-9a-f]+)?\.ico}
  end
end
