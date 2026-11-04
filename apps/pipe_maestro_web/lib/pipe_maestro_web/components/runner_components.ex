defmodule PipeMaestroWeb.RunnerComponents do
  @moduledoc "Pieces every runner screen shares: status, last seen, how to connect."
  use PipeMaestroWeb, :html

  alias PipeMaestro.Runners
  alias PipeMaestro.Runners.Runner

  @doc "Online/offline badge."
  attr :online, :boolean, required: true
  attr :rest, :global

  @spec runner_status(map()) :: Phoenix.LiveView.Rendered.t()
  def runner_status(assigns) do
    ~H"""
    <.badge :if={@online} size="sm" variant="soft" color="success" dot label="Online" {@rest} />
    <.badge :if={!@online} size="sm" variant="soft" color="gray" dot label="Offline" {@rest} />
    """
  end

  @doc """
  The version a runner announced, with a "desatualizado" badge when it is a
  release older than this control plane's (`Runners.outdated?/1`).
  """
  attr :runner, Runner, required: true
  attr :version_testid, :string, required: true, doc: "test id of the version"
  attr :outdated_testid, :string, required: true, doc: "test id of the badge"

  @spec runner_version(map()) :: Phoenix.LiveView.Rendered.t()
  def runner_version(assigns) do
    assigns =
      assign(assigns,
        version: assigns.runner.runner_version || "—",
        outdated: Runners.outdated?(assigns.runner)
      )

    ~H"""
    <span class="inline-flex flex-wrap items-center gap-1.5">
      <span class="whitespace-nowrap font-mono" data-testid={@version_testid}>{@version}</span>
      <.badge
        :if={@outdated}
        size="xs"
        variant="soft"
        color="warning"
        label="desatualizado"
        data-testid={@outdated_testid}
      />
    </span>
    """
  end

  @doc ~s(How long ago a moment was, in short Portuguese: "agora", "há 5 min".)
  @spec time_ago(DateTime.t() | nil, DateTime.t()) :: String.t()
  def time_ago(datetime, now \\ DateTime.utc_now())
  def time_ago(nil, _now), do: "nunca"

  def time_ago(%DateTime{} = datetime, now) do
    seconds = max(DateTime.diff(now, datetime), 0)

    cond do
      seconds < 60 -> "agora"
      seconds < 3_600 -> "há #{div(seconds, 60)} min"
      seconds < 86_400 -> "há #{div(seconds, 3_600)} h"
      true -> "há #{div(seconds, 86_400)} d"
    end
  end

  @doc ~s(A size in bytes, short, with a decimal comma: "1,5 GB", "50 GB", "0 B".)
  @spec format_bytes(non_neg_integer()) :: String.t()
  def format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"

  def format_bytes(bytes) do
    {value, unit} = scale(bytes / 1024, ~w(KB MB GB TB))

    number =
      if value >= 10,
        do: value |> round() |> Integer.to_string(),
        else: :erlang.float_to_binary(value, decimals: 1)

    "#{String.replace(number, ".", ",")} #{unit}"
  end

  defp scale(value, [_unit | rest]) when value >= 1024 and rest != [],
    do: scale(value / 1024, rest)

  defp scale(value, [unit | _rest]), do: {value, unit}

  @doc "The commands that connect a new runner to this platform."
  attr :url, :string, required: true, doc: "the platform URL the runner should use"

  @spec connect_instructions(map()) :: Phoenix.LiveView.Rendered.t()
  def connect_instructions(assigns) do
    ~H"""
    <ol class="space-y-4 text-sm text-gray-600 dark:text-gray-300">
      <li>
        <p class="font-medium text-gray-900 dark:text-white">
          1. Na máquina do runner, dentro do repositório:
        </p>
        <pre
          class="mt-2 overflow-x-auto rounded-lg bg-gray-900 px-4 py-3 font-mono text-xs text-gray-100"
          data-testid="connect-login-command"
        >make runner.login URL={@url}</pre>
      </li>
      <li>
        <p class="font-medium text-gray-900 dark:text-white">
          2. Abra o link que o comando mostrar e aprove o runner neste workspace.
        </p>
      </li>
      <li>
        <p class="font-medium text-gray-900 dark:text-white">3. Conecte:</p>
        <pre class="mt-2 overflow-x-auto rounded-lg bg-gray-900 px-4 py-3 font-mono text-xs text-gray-100">make runner.start</pre>
      </li>
    </ol>
    """
  end
end
