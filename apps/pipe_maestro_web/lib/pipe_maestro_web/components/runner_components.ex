defmodule PipeMaestroWeb.RunnerComponents do
  @moduledoc """
  Pieces every runner screen shares: status, last seen, how to connect, and
  how near its account is to its usage limits.
  """
  use PipeMaestroWeb, :html

  alias PipeMaestro.Runners
  alias PipeMaestro.Runners.Runner
  alias PipeMaestroProtocol.Downloads

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

  @doc ~s(A share of time connected, with one decimal and a comma: "97,8%"; "—" for none.)
  @spec format_uptime(float() | nil) :: String.t()
  def format_uptime(nil), do: "—"

  def format_uptime(share) do
    (share * 100)
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.replace(".", ",")
    |> Kernel.<>("%")
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

  # The screen's name for each target the deploy publishes a binary for.
  @target_labels %{
    "macos_arm64" => {"macOS", "Apple Silicon"},
    "macos_x86_64" => {"macOS", "Intel"},
    "linux_x86_64" => {"Linux", "x86_64"},
    "linux_arm64" => {"Linux", "arm64"}
  }

  @downloads (for target <- Downloads.targets() do
                {os, arch} = Map.fetch!(@target_labels, target)
                {target, os, arch}
              end)

  @doc """
  Where this deploy published the runner's binaries (`:runner_downloads_url`),
  or nil where none were (development and tests).
  """
  @spec downloads_url() :: String.t() | nil
  def downloads_url, do: Application.get_env(:pipe_maestro_web, :runner_downloads_url)

  @doc """
  Links to the runner's binary for each platform, of the runner's version this
  control plane requires, and the command that installs one.
  """
  attr :url, :string, required: true, doc: "the platform URL"
  attr :downloads, :string, required: true, doc: "where the binaries are, under the platform"
  attr :version, :string, required: true, doc: "the runner's version they were built as"

  @spec runner_downloads(map()) :: Phoenix.LiveView.Rendered.t()
  def runner_downloads(assigns) do
    assigns = assign(assigns, targets: @downloads, base: binary_base(assigns))

    ~H"""
    <div data-testid="runner-downloads">
      <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
        <a
          :for={{target, os, arch} <- @targets}
          href={"#{@downloads}/#{Downloads.binary_name(target)}"}
          download={"pipemaestro_#{target}"}
          class="flex items-center gap-3 rounded-lg border border-gray-200 px-3 py-2.5 transition hover:border-primary-400 hover:bg-primary-50 dark:border-gray-700 dark:hover:border-primary-500 dark:hover:bg-gray-800"
          data-testid={"runner-download-#{target}"}
        >
          <.icon
            name={if os == "macOS", do: "hero-computer-desktop", else: "hero-server"}
            class="size-5 shrink-0 text-gray-400"
          />
          <span class="min-w-0 flex-1">
            <span class="block text-sm font-medium text-gray-900 dark:text-white">{os}</span>
            <span class="block text-xs text-gray-500 dark:text-gray-400">{arch}</span>
          </span>
          <.icon name="hero-arrow-down-tray" class="size-4 shrink-0 text-primary-500" />
        </a>
      </div>
      <p class="mt-3 text-xs text-gray-500 dark:text-gray-400">
        Versão <span class="font-mono" data-testid="runner-download-version">{@version}</span>,
        a que esta plataforma pede. Pelo terminal, o macOS não pede para liberar o app
        (troque <span class="font-mono">macos_arm64</span> pelo seu alvo):
      </p>
      <pre
        class="mt-2 overflow-x-auto rounded-lg bg-gray-900 px-4 py-3 font-mono text-xs text-gray-100 dark:bg-gray-950 dark:ring-1 dark:ring-gray-700"
        data-testid="runner-download-command"
      >{install_command(@base)}</pre>
    </div>
    """
  end

  defp install_command(base) do
    Enum.join(
      [
        "mkdir -p ~/.local/bin",
        "curl -fL #{base}_macos_arm64 -o ~/.local/bin/pipemaestro",
        "chmod +x ~/.local/bin/pipemaestro"
      ],
      "\n"
    )
  end

  defp binary_base(%{url: url, downloads: downloads}) do
    base = if String.starts_with?(downloads, "/"), do: url <> downloads, else: downloads
    base <> "/pipemaestro"
  end

  @doc """
  The commands that connect a new runner to this platform: with published
  binaries, download one and use it (`login` names the platform only when it
  is not the default one); without them, the repository's make targets. Both
  name the runner's version the platform requires.
  """
  attr :url, :string, required: true, doc: "the platform URL the runner should use"
  attr :downloads, :string, default: nil, doc: "where the binaries are, if published"
  attr :version, :string, required: true, doc: "the runner's version the platform requires"

  @spec connect_instructions(map()) :: Phoenix.LiveView.Rendered.t()
  def connect_instructions(%{downloads: downloads} = assigns) when is_binary(downloads) do
    login =
      if assigns.url == PipeMaestroProtocol.default_platform_url(),
        do: "pipemaestro login",
        else: "pipemaestro login --url #{assigns.url}"

    assigns = assign(assigns, login: login)

    ~H"""
    <.expected_version version={@version} />
    <ol class="space-y-4 text-sm text-gray-600 dark:text-gray-300">
      <li>
        <p class="font-medium text-gray-900 dark:text-white">
          1. Baixe o runner da sua plataforma:
        </p>
        <div class="mt-2">
          <.runner_downloads url={@url} downloads={@downloads} version={@version} />
        </div>
      </li>
      <li>
        <p class="font-medium text-gray-900 dark:text-white">
          2. Faça login, abra o link que o comando mostrar e aprove o runner neste workspace:
        </p>
        <pre
          class="mt-2 overflow-x-auto rounded-lg bg-gray-900 px-4 py-3 font-mono text-xs text-gray-100 dark:bg-gray-950 dark:ring-1 dark:ring-gray-700"
          data-testid="connect-login-command"
        >{@login}</pre>
      </li>
      <li>
        <p class="font-medium text-gray-900 dark:text-white">3. Conecte:</p>
        <pre class="mt-2 overflow-x-auto rounded-lg bg-gray-900 px-4 py-3 font-mono text-xs text-gray-100 dark:bg-gray-950 dark:ring-1 dark:ring-gray-700">pipemaestro start --root ~/src</pre>
      </li>
    </ol>
    """
  end

  def connect_instructions(assigns) do
    ~H"""
    <.expected_version version={@version} />
    <ol class="space-y-4 text-sm text-gray-600 dark:text-gray-300">
      <li>
        <p class="font-medium text-gray-900 dark:text-white">
          1. Na máquina do runner, dentro do repositório:
        </p>
        <pre
          class="mt-2 overflow-x-auto rounded-lg bg-gray-900 px-4 py-3 font-mono text-xs text-gray-100 dark:bg-gray-950 dark:ring-1 dark:ring-gray-700"
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
        <pre class="mt-2 overflow-x-auto rounded-lg bg-gray-900 px-4 py-3 font-mono text-xs text-gray-100 dark:bg-gray-950 dark:ring-1 dark:ring-gray-700">make runner.start</pre>
      </li>
    </ol>
    """
  end

  attr :version, :string, required: true

  defp expected_version(assigns) do
    ~H"""
    <p class="mb-4 flex flex-wrap items-center gap-2 text-sm text-gray-600 dark:text-gray-300">
      A plataforma pede o runner na versão
      <.badge
        size="sm"
        variant="soft"
        color="primary"
        class="font-mono"
        label={@version}
        data-testid="runners-expected-version"
      />
    </p>
    """
  end

  @doc """
  The account's usage limits as the last run on `runner` saw them: each
  window's use as a bar, the status and when the limit resets. Nothing when
  no run reported them.
  """
  attr :runner, Runner, required: true
  attr :testid, :string, required: true, doc: "test id prefix; each window adds `-<window>`"

  @spec rate_limit(map()) :: Phoenix.LiveView.Rendered.t()
  def rate_limit(%{runner: %Runner{rate_limit: %{} = limit}} = assigns) do
    assigns =
      assign(assigns,
        windows: Enum.sort(limit["utilization"] || %{}),
        status: limit["status"],
        resets_at: Runners.resets_at(limit["resets_at"]),
        near: Runners.near_limit?(assigns.runner)
      )

    ~H"""
    <div class="space-y-2" data-testid={@testid}>
      <div class="flex flex-wrap items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
        <.badge
          size="xs"
          variant="soft"
          color={if @near, do: "warning", else: "success"}
          label={if @near, do: "perto do limite", else: @status || "—"}
          data-testid={"#{@testid}-status"}
        />
        <span :if={@resets_at}>renova {format_reset(@resets_at)}</span>
      </div>
      <div
        :for={{window, used} <- @windows}
        class="grid grid-cols-[6rem_1fr_3rem] items-center gap-2 text-xs"
        data-testid={"#{@testid}-#{window}"}
      >
        <span class="truncate text-gray-500 dark:text-gray-400">{window_label(window)}</span>
        <.progress
          size="sm"
          value={percent(used)}
          color={if percent(used) >= 80, do: "warning", else: "primary"}
        />
        <span class="text-right text-gray-900 dark:text-white">{percent(used)}%</span>
      </div>
    </div>
    """
  end

  def rate_limit(assigns), do: ~H""

  defp percent(used) when is_number(used), do: used |> Kernel.*(100) |> round() |> min(100)
  defp percent(_unknown), do: 0

  defp window_label("five_hour"), do: "5 horas"
  defp window_label("seven_day"), do: "7 dias"
  defp window_label("seven_day_opus"), do: "7 dias (Opus)"
  defp window_label("seven_day_sonnet"), do: "7 dias (Sonnet)"
  defp window_label(window), do: window

  defp format_reset(%DateTime{} = at), do: Calendar.strftime(at, "%d/%m %H:%M UTC")
end
