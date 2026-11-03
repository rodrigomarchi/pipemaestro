defmodule Mix.Tasks.Runner.Login do
  @shortdoc "Signs this runner in to the platform (device flow)"
  @moduledoc """
  Signs this machine in as a runner:

      mix runner.login --url http://localhost:4000 [--name NAME] [--label L]... [--capacity N]

  Shows a URL and a code; a workspace member opens the URL, signed in, and
  approves the runner. The credentials are saved for `mix runner.start`.
  """
  use Mix.Task

  alias ClaudeControlPlaneRunner.{CLI, Config, DeviceLogin, Host}

  @switches [url: :string, name: :string, label: :keep, capacity: :integer]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("Opção inválida: #{inspect(invalid)}")
    url = opts[:url] || Mix.raise("Informe a URL da plataforma: --url http://localhost:4000")

    CLI.start!()

    labels = Keyword.get_values(opts, :label)
    {:ok, hello} = Host.hello(labels: labels, capacity: opts[:capacity])

    Mix.shell().info("Pedindo acesso a #{url} para #{hello.hostname}...")

    case DeviceLogin.run(String.trim_trailing(url, "/"), hello,
           name: opts[:name],
           on_code: &show_code/1
         ) do
      {:ok, result} ->
        result
        |> Map.merge(%{
          url: String.trim_trailing(url, "/"),
          labels: labels,
          capacity: opts[:capacity]
        })
        |> Config.save()

        Mix.shell().info("""

        Runner "#{result.runner_name}" conectado ao workspace #{result.workspace_name}.
        Credenciais salvas em #{Config.path()}.
        Para ficar online: make runner.start
        """)

      {:error, :denied} ->
        Mix.raise("O pedido foi recusado na plataforma.")

      {:error, :expired} ->
        Mix.raise("O código expirou antes de ser aprovado. Rode o login de novo.")

      {:error, {:unreachable, exception}} ->
        Mix.raise("Não foi possível falar com #{url}: #{Exception.message(exception)}")

      {:error, {:unexpected, detail}} ->
        Mix.raise("Resposta inesperada da plataforma: #{inspect(detail)}")
    end
  end

  defp show_code(code) do
    Mix.shell().info("""

    Abra #{code.verification_uri}
    e digite o código:  #{code.user_code}

    Ou acesse direto: #{code.verification_uri_complete}

    Aguardando aprovação (o código vale #{div(code.expires_in, 60)} minutos)...
    """)
  end
end
