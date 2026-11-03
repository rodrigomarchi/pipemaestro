defmodule ClaudeControlPlaneWeb.RunnerComponents do
  @moduledoc "Pieces every runner screen shares: status, last seen, how to connect."
  use ClaudeControlPlaneWeb, :html

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
