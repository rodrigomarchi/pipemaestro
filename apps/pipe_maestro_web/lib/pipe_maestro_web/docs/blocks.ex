defmodule PipeMaestroWeb.Docs.Blocks do
  @moduledoc """
  A documentation page's Markdown as the blocks its template renders. A line
  holding only `{{tela:<name>}}` becomes a screenshot of the platform
  (`PipeMaestroWeb.LandingShots.fetch/1`), shown light and dark; the rest is
  HTML, with GitHub's tables and an anchor on every heading.
  """

  alias PipeMaestroWeb.LandingShots

  @type t :: {:html, String.t()} | {:shot, LandingShots.shot()}

  @shot_line ~r/^\{\{tela:([a-z0-9-]+)\}\}$/m
  @markdown [
    extension: [table: true, strikethrough: true, autolink: true, header_id_prefix: ""],
    render: [unsafe: false]
  ]

  @doc """
  The blocks of `markdown`, the page `slug`'s source. Raises on a screenshot
  `LandingShots` does not know, so a typo fails the build.
  """
  @spec render(String.t(), String.t()) :: [t()]
  def render(markdown, slug) do
    @shot_line
    |> Regex.split(markdown, include_captures: true, trim: true)
    |> Enum.map(&block(&1, slug))
    |> Enum.reject(&match?({:html, ""}, &1))
  end

  defp block(chunk, slug) do
    case Regex.run(@shot_line, chunk) do
      [_line, name] -> {:shot, shot!(name, slug)}
      nil -> {:html, chunk |> MDEx.to_html!(@markdown) |> String.trim() |> label_anchors()}
    end
  end

  # MDEx labels a heading's anchor in English; the pages are in Portuguese.
  defp label_anchors(html),
    do:
      String.replace(html, ~s(aria-label="Link to heading '), ~s(aria-label="Link para a seção '))

  defp shot!(name, slug) do
    case LandingShots.fetch(name) do
      {:ok, shot} -> shot
      :error -> raise ArgumentError, "priv/docs/#{slug}.md: unknown screenshot #{inspect(name)}"
    end
  end
end
