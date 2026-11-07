defmodule PipeMaestroWeb.Markdown do
  @moduledoc """
  Markdown written by agents (artifacts, answers), rendered to HTML on the
  server with GitHub's extensions (tables, task lists, strikethrough,
  autolinks). The source is not trusted: raw HTML is dropped and unsafe link
  targets (`javascript:` and the like) are emptied, so the result can go into
  a page as is.
  """

  @options [
    extension: [table: true, strikethrough: true, tasklist: true, autolink: true],
    render: [unsafe: false]
  ]

  @doc "The HTML for `markdown`, safe to put in a template."
  @spec to_html(String.t() | nil) :: Phoenix.HTML.safe()
  def to_html(nil), do: Phoenix.HTML.raw("")

  def to_html(markdown) when is_binary(markdown) do
    case MDEx.to_html(markdown, @options) do
      {:ok, html} -> Phoenix.HTML.raw(html)
      {:error, _reason} -> Phoenix.HTML.html_escape(markdown)
    end
  end

  @doc """
  The HTML for a short `markdown` that sits inside a line (a summary, a
  question): a text of one paragraph loses its `<p>`, so it flows with what
  surrounds it; longer text keeps its blocks.
  """
  @spec inline_html(String.t() | nil) :: Phoenix.HTML.safe()
  def inline_html(nil), do: Phoenix.HTML.raw("")

  def inline_html(markdown) when is_binary(markdown) do
    case MDEx.to_html(markdown, @options) do
      {:ok, html} -> html |> String.trim() |> unwrap_paragraph() |> Phoenix.HTML.raw()
      {:error, _reason} -> Phoenix.HTML.html_escape(markdown)
    end
  end

  defp unwrap_paragraph("<p>" <> rest = html) do
    inner = String.replace_suffix(rest, "</p>", "")
    if String.contains?(inner, "<p>"), do: html, else: inner
  end

  defp unwrap_paragraph(html), do: html
end
