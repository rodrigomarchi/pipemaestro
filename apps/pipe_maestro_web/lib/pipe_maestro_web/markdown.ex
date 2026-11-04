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
end
