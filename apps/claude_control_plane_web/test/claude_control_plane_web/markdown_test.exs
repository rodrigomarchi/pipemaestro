defmodule ClaudeControlPlaneWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias ClaudeControlPlaneWeb.Markdown

  defp html(markdown), do: markdown |> Markdown.to_html() |> Phoenix.HTML.safe_to_string()

  test "renders headings, lists, tables, code and task lists" do
    html =
      html("""
      # Triagem

      - **bem definida**: sim
      - [x] reproduzido

      | arquivo | linhas |
      |---|---|
      | lib/a.ex | 3 |

      ```elixir
      def a, do: 1
      ```
      """)

    assert html =~ "<h1>Triagem</h1>"
    assert html =~ "<strong>bem definida</strong>"
    assert html =~ ~s(<input type="checkbox" checked="" disabled="" />)
    assert html =~ "<table>"
    assert html =~ ~s(<code class="language-elixir">)
  end

  test "drops raw HTML and unsafe links" do
    html = html("<script>alert(1)</script>\n\n[x](javascript:alert(1)) <img src=x onerror=1>")

    refute html =~ "<script"
    refute html =~ "javascript:"
    refute html =~ "onerror"
  end

  test "links open outside the app" do
    assert html("https://example.com") =~ ~s(href="https://example.com")
  end

  test "nil renders nothing" do
    assert html(nil) == ""
  end
end
