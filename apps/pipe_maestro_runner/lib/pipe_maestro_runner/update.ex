defmodule PipeMaestroRunner.Update do
  @moduledoc """
  What the runner says when the platform refuses it for not being on the
  platform's version (`"outdated"`, on login and on every join): which
  version it runs, which one the platform wants, and where to download it.
  """

  @doc ~s(The message for a refusal: `%{"version", "runner_version", "download_url"}`.)
  @spec message(map()) :: String.t()
  def message(refusal) do
    """
    Este runner está na versão #{refusal["runner_version"] || "?"}, e a plataforma está na \
    #{refusal["version"] || "?"}: só a versão da plataforma conecta.

    Baixe a versão atual em #{refusal["download_url"] || "a tela Executores da plataforma"}, \
    substitua o binário (no repositório: atualize o código) e rode de novo.
    """
  end
end
