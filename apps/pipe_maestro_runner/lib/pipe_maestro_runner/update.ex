defmodule PipeMaestroRunner.Update do
  @moduledoc """
  What the runner does when the platform refuses it for not being on the
  runner's version the platform asks for (`"outdated"`, on login and on every
  join).

  As a single binary (Burrito's `__BURRITO_BIN_PATH`) it offers to download
  and install that version in its place, and runs the same command
  again without asking, in a terminal or not: how the new binary runs comes
  from `PipeMaestroRunner.SelfUpdate.mode/2` (the service manager, the runner
  waiting in the terminal, or on its own), so it always comes back. With
  `--no-auto-update` it asks in a terminal instead.
  Otherwise (Mix, a release, `--no-auto-update` without a terminal, a "no")
  it says which version it runs, which one the platform wants, and where to
  download it.

  With a `:marker` path, an attempt to update leaves there what happened
  (`take_marker/1`), for the runner that starts next to tell its log
  (`update_applied` or `update_failed`, ADR 0039).
  """

  alias PipeMaestroRunner.{Host, Output, SelfUpdate}

  @doc """
  Reads and removes what the last attempt to update left at `path`:
  `{:applied | :failed, %{"from", "to", "reason"?}}`, or `nil`.
  """
  @spec take_marker(Path.t()) :: {:applied | :failed, map()} | nil
  def take_marker(path) do
    with {:ok, binary} <- File.read(path),
         _removed <- File.rm(path),
         {:ok, %{"result" => result} = marker} when result in ["applied", "failed"] <-
           JSON.decode(binary) do
      {String.to_existing_atom(result), Map.delete(marker, "result")}
    else
      _none -> nil
    end
  end

  defp mark(nil, _result, _refusal, _reason), do: :ok

  defp mark(path, result, refusal, reason) do
    marker =
      %{"result" => result, "from" => Host.runner_version(), "to" => refusal["version"]}
      |> then(&if(reason, do: Map.put(&1, "reason", reason), else: &1))

    _written = File.write(path, JSON.encode!(marker))
    :ok
  end

  @doc ~s(The message for a refusal: `%{"version", "runner_version", "download_url"}`.)
  @spec message(map()) :: String.t()
  def message(refusal) do
    """
    Este runner está na versão #{refusal["runner_version"] || "?"}, e a plataforma pede a \
    versão #{refusal["version"] || "?"} do runner: só ela conecta.

    Baixe a versão atual em #{refusal["download_url"] || "a tela Executores da plataforma"}, \
    substitua o binário (no repositório: atualize o código) e rode de novo.
    """
  end

  @doc "The question asked in a terminal before updating."
  @spec prompt(map()) :: String.t()
  def prompt(refusal) do
    """
    Este runner está na versão #{refusal["runner_version"] || "?"} e a plataforma pede a \
    versão #{refusal["version"] || "?"} do runner.
    Baixar e instalar a versão #{refusal["version"] || "?"} agora? [S/n]\
    """
  end

  @doc """
  What to do by hand when the binary's directory cannot be written to: `urls`
  are `SelfUpdate.urls/3`'s, `bin` the binary to replace.
  """
  @spec manual(SelfUpdate.urls(), Path.t()) :: String.t()
  def manual(urls, bin) do
    name = Path.basename(urls.binary)

    """
    Não foi possível trocar o binário: sem permissão de escrita em #{Path.dirname(bin)}.
    Para atualizar à mão, com um usuário que possa escrever lá:

      cd "$(mktemp -d)"
      curl -fLO #{urls.binary}
      curl -fLO #{urls.checksums}
      grep ' #{name}$' SHA256SUMS | shasum -a 256 -c
      chmod 0755 #{name}
      mv #{name} #{bin}
    """
  end

  @doc """
  Handles a refusal: updates the binary and runs the same command again
  (returning what `:relaunch` returns), or returns `{:fail, message}` for the
  command to stop with.

  Options: `:argv` (the command, to run again), `:auto_update` (`false`,
  from `--no-auto-update`, asks in a terminal and otherwise gives the message;
  omitted or `true`, it updates without asking),
  `:platform_url` (where the runner connects; the binary comes only from its
  origin), `:marker` (where to leave what happened), and what comes from the environment by default: `:env`
  (`System.get_env/0`), `:tty?` (`Output.tty?/0`), `:gets` (reads the answer
  to the question, `Output.ask/1`) and `:relaunch`
  (`SelfUpdate.relaunch/3`, then exits with the new binary's status).
  """
  @spec handle(map(), keyword()) :: {:fail, String.t()} | term()
  def handle(refusal, opts) do
    opts = Keyword.merge(defaults(), opts)

    with {:ok, bin} <- single_binary(opts[:env]),
         :ok <- consent(refusal, opts) do
      install(refusal, bin, SelfUpdate.mode(opts[:env], opts[:tty?] == true), opts)
    else
      :refused -> {:fail, message(refusal)}
    end
  end

  defp defaults do
    base = [
      env: System.get_env(),
      tty?: Output.tty?(),
      gets: &Output.ask/1,
      relaunch: &relaunch/3
    ]

    # MIX_ENV=e2e: the question as in a terminal, for a binary that is only a path.
    case Application.get_env(:pipe_maestro_runner, :update_prompt) do
      [binary: bin] -> Keyword.merge(base, tty?: true, env: %{"__BURRITO_BIN_PATH" => bin})
      nil -> base
    end
  end

  defp single_binary(%{"__BURRITO_BIN_PATH" => bin}) when bin != "", do: {:ok, bin}
  defp single_binary(_env), do: :refused

  defp consent(refusal, opts) do
    cond do
      opts[:auto_update] != false -> :ok
      opts[:tty?] != true -> :refused
      yes?(opts[:gets].(prompt(refusal))) -> :ok
      true -> :refused
    end
  end

  defp yes?(answer) when is_binary(answer),
    do: (answer |> String.trim() |> String.downcase()) in ["", "s", "sim", "y", "yes"]

  defp yes?(_eof), do: false

  defp install(refusal, bin, mode, opts) do
    with {:ok, target} <- SelfUpdate.target(),
         {:ok, urls} <- SelfUpdate.urls(opts[:platform_url], refusal["download_url"], target) do
      Output.info("Baixando a versão #{refusal["version"]} de #{urls.binary}...")

      case SelfUpdate.install(bin, urls: urls, target: target, progress: &Output.progress/1) do
        :ok ->
          Output.info("Atualizado para a versão #{refusal["version"]}. Rodando de novo...")
          mark(opts[:marker], "applied", refusal, nil)
          opts[:relaunch].(bin, opts[:argv], mode)

        {:error, {:not_writable, dir}} ->
          mark(opts[:marker], "failed", refusal, "sem permissão de escrita em #{dir}")
          {:fail, manual(urls, bin)}

        {:error, reason} ->
          mark(opts[:marker], "failed", refusal, describe(reason))
          {:fail, "Não foi possível atualizar: #{describe(reason)}.\n\n" <> message(refusal)}
      end
    else
      {:error, reason} ->
        mark(opts[:marker], "failed", refusal, describe(reason))
        {:fail, "Não foi possível atualizar: #{describe(reason)}.\n\n" <> message(refusal)}
    end
  end

  defp describe(:unsupported_platform), do: "não há binário publicado para esta plataforma"

  defp describe(:foreign_origin),
    do: "o endereço de download não está na origem da plataforma (ou não usa https)"

  defp describe(:checksum_mismatch), do: "o SHA-256 baixado não confere com o SHA256SUMS"
  defp describe({:missing_checksum, name}), do: "#{name} não está no SHA256SUMS"
  defp describe({:http_status, status, url}), do: "#{url} respondeu #{status}"
  defp describe({:download, url, exception}), do: "#{url}: #{Exception.message(exception)}"
  defp describe({:file, path, reason}), do: "#{path}: #{:file.format_error(reason)}"

  # The new binary takes over: this one exits with its status, or stops with
  # why the new one could not start.
  @spec relaunch(Path.t(), [String.t()], SelfUpdate.mode()) :: {:fail, String.t()}
  defp relaunch(bin, argv, mode) do
    case SelfUpdate.relaunch(bin, argv, mode) do
      status when is_integer(status) -> System.halt(status)
      {:error, reason} -> {:fail, "Atualizado, mas o binário novo não subiu: #{reason}."}
    end
  end
end
