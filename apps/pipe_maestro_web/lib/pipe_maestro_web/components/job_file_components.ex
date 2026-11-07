defmodule PipeMaestroWeb.JobFileComponents do
  @moduledoc """
  The files a job left in `CP_FILES_DIR` (`PipeMaestro.Jobs.Files`): raster
  images as thumbnails that open full size, every other file as a link that
  downloads it.
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.RunnerComponents, only: [format_bytes: 1]

  alias PipeMaestro.Jobs.{Files, JobFile}

  @doc """
  A job's files. Each test id is `<testid>-<key>-<path>`, `<testid>-thumb-…`
  for an image's thumbnail and `<testid>-download-…` for its link.
  """
  attr :files, :list, required: true, doc: "the `t:PipeMaestro.Jobs.JobFile.t/0` to show"
  attr :workspace_slug, :string, required: true
  attr :testid, :string, required: true, doc: "prefix of each file's test ids"
  attr :key, :string, required: true, doc: "what tells these files apart: `<stage>-<attempt>`"
  attr :rest, :global

  @spec files(map()) :: Phoenix.LiveView.Rendered.t()
  def files(assigns) do
    {images, others} = Enum.split_with(assigns.files, &Files.image?/1)
    assigns = assign(assigns, images: images, others: others)

    ~H"""
    <div class="space-y-3" {@rest}>
      <div :if={@images != []} class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
        <figure
          :for={file <- @images}
          class="overflow-hidden rounded-lg border border-gray-200 dark:border-gray-800"
          data-testid={"#{@testid}-#{@key}-#{file.path}"}
        >
          <.link
            href={href(@workspace_slug, file)}
            target="_blank"
            rel="noopener"
            title={"Abrir #{file.path} em tamanho real"}
            data-testid={"#{@testid}-download-#{@key}-#{file.path}"}
          >
            <img
              src={href(@workspace_slug, file)}
              alt={file.path}
              loading="lazy"
              class="aspect-video w-full bg-gray-50 object-contain dark:bg-gray-950"
              data-testid={"#{@testid}-thumb-#{@key}-#{file.path}"}
            />
          </.link>
          <figcaption class="flex items-center justify-between gap-2 border-t border-gray-200 px-2 py-1 text-xs text-gray-600 dark:border-gray-800 dark:text-gray-400">
            <span class="truncate" title={file.path}>{file.path}</span>
            <span class="shrink-0">{format_bytes(file.byte_size)}</span>
          </figcaption>
        </figure>
      </div>

      <ul
        :if={@others != []}
        class="divide-y divide-gray-100 rounded-lg border border-gray-200 dark:divide-gray-800 dark:border-gray-800"
      >
        <li
          :for={file <- @others}
          class="flex items-center gap-2 px-3 py-2 text-sm"
          data-testid={"#{@testid}-#{@key}-#{file.path}"}
        >
          <.icon name="hero-document-arrow-down" class="size-4 shrink-0 text-gray-500" />
          <.link
            href={href(@workspace_slug, file)}
            class="truncate text-primary-600 hover:underline dark:text-primary-400"
            title={"Baixar #{file.path}"}
            data-testid={"#{@testid}-download-#{@key}-#{file.path}"}
          >
            {file.path}
          </.link>
          <span class="ml-auto shrink-0 text-xs text-gray-500 dark:text-gray-400">
            {format_bytes(file.byte_size)}
          </span>
        </li>
      </ul>
    </div>
    """
  end

  @doc "How many of a job's files did not reach the platform, as a warning."
  attr :count, :integer, required: true
  attr :rest, :global

  @spec files_failed(map()) :: Phoenix.LiveView.Rendered.t()
  def files_failed(assigns) do
    ~H"""
    <.alert color="warning" with_icon {@rest}>
      {@count} {if @count == 1, do: "arquivo não chegou", else: "arquivos não chegaram"} à plataforma: veja o log do runner.
    </.alert>
    """
  end

  defp href(workspace_slug, %JobFile{id: id}), do: ~p"/w/#{workspace_slug}/files/#{id}"
end
