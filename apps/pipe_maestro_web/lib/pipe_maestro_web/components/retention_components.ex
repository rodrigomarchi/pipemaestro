defmodule PipeMaestroWeb.RetentionComponents do
  @moduledoc """
  A workspace's retention as people read it (ADR 0054): what its files take
  against its quota (`PipeMaestro.Jobs.Files.workspace_usage/1`) and the
  policies in force for its files and its agent's events. The backoffice and
  the members' usage page show the same text.
  """
  use PipeMaestroWeb, :html

  alias PipeMaestro.Workspaces.Workspace

  @mib 1_048_576

  @doc """
  Bytes in MiB, as Brazilians write numbers: `"1.024 MiB"`, `"0,6 MiB"`.
  Whole from 10 MiB on, or when exact; one decimal below; `"< 0,1 MiB"` for
  less than that.
  """
  @spec format_mib(non_neg_integer()) :: String.t()
  def format_mib(bytes) when is_integer(bytes) and bytes > 0 and bytes < div(@mib, 20),
    do: "< 0,1 MiB"

  def format_mib(bytes) when is_integer(bytes) and bytes >= 0 do
    mib = bytes / @mib

    number =
      if mib >= 10 or rem(bytes, @mib) == 0,
        do: mib |> round() |> group_thousands(),
        else: mib |> Float.round(1) |> :erlang.float_to_binary(decimals: 1) |> decimal_comma()

    number <> " MiB"
  end

  defp group_thousands(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.join(".")
    |> String.reverse()
  end

  defp decimal_comma(number), do: String.replace(number, ".", ",")

  @doc ~S"""
  What the files take against the quota: `"312 MiB de 1.024 MiB"`, or
  `"312 MiB, sem cota"` without one.
  """
  @spec usage_label(%{bytes: non_neg_integer(), quota_bytes: pos_integer() | nil}) ::
          String.t()
  def usage_label(%{bytes: bytes, quota_bytes: nil}), do: "#{format_mib(bytes)}, sem cota"

  def usage_label(%{bytes: bytes, quota_bytes: quota}),
    do: "#{format_mib(bytes)} de #{format_mib(quota)}"

  @doc "The files against the quota, as text, with a bar when there is a quota."
  attr :usage, :map, required: true, doc: "`PipeMaestro.Jobs.Files.workspace_usage/1`"
  attr :testid, :string, required: true
  attr :class, :any, default: nil

  @spec files_usage(map()) :: Phoenix.LiveView.Rendered.t()
  def files_usage(assigns) do
    ~H"""
    <div class={["space-y-2", @class]}>
      <p class="text-sm font-medium text-gray-900 dark:text-white" data-testid={@testid}>
        {usage_label(@usage)}
      </p>
      <.progress
        :if={@usage.quota_bytes}
        size="sm"
        color={if @usage.bytes >= @usage.quota_bytes, do: "danger", else: "primary"}
        value={min(@usage.bytes, @usage.quota_bytes)}
        max={@usage.quota_bytes}
      />
    </div>
    """
  end

  @doc "The retention policies in force for a workspace's files and agent's events."
  attr :workspace, Workspace, required: true
  attr :rest, :global

  @spec retention_policy(map()) :: Phoenix.LiveView.Rendered.t()
  def retention_policy(assigns) do
    ~H"""
    <dl class="grid gap-x-6 gap-y-2 text-sm sm:grid-cols-2" {@rest}>
      <div>
        <dt class="text-gray-500 dark:text-gray-400">Anexos</dt>
        <dd class="text-gray-900 dark:text-white">{files_policy(@workspace)}</dd>
      </div>
      <div>
        <dt class="text-gray-500 dark:text-gray-400">Eventos do agente</dt>
        <dd class="text-gray-900 dark:text-white">{events_policy(@workspace)}</dd>
      </div>
    </dl>
    """
  end

  @doc "How long the workspace's files keep their content."
  @spec files_policy(Workspace.t()) :: String.t()
  def files_policy(%Workspace{job_files_retention_days: nil}),
    do: "conteúdo guardado sem limite de dias"

  def files_policy(%Workspace{job_files_retention_days: days}),
    do: "conteúdo guardado por #{days_label(days)}, depois só o nome"

  @doc "How long the agent's events stay whole, and what then happens to them."
  @spec events_policy(Workspace.t()) :: String.t()
  def events_policy(%Workspace{agent_events_retention_days: days} = workspace),
    do: "completos por #{days_label(days)} após o fim do job; #{after_label(workspace)}"

  defp after_label(%Workspace{agent_events_after_retention: :delete}), do: "depois, apagados"
  defp after_label(%Workspace{}), do: "depois, só os metadados"

  defp days_label(1), do: "1 dia"
  defp days_label(days), do: "#{days} dias"
end
