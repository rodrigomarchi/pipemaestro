defmodule PipeMaestroRunner.Commands.Login do
  @moduledoc """
  Signs this machine in as a runner:

      pipemaestro login [--url URL] [--name NAME] [--label L]... [--capacity N]

  Without `--url`, it signs in to `PipeMaestroRunner.Config.default_url/0`
  (PipeMaestro's production, or `$PIPEMAESTRO_URL`). Shows a URL and a code; a workspace member opens the URL, signed in, and
  approves the runner. The credentials are saved for `pipemaestro start`.
  """

  alias PipeMaestroRunner.{Config, DeviceLogin, Host, Output}

  @switches [url: :string, name: :string, label: :keep, capacity: :integer]
  @spec run([String.t()]) :: any()
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Output.fail!("Opção inválida: #{inspect(invalid)}")
    url = opts[:url] || Config.default_url()

    labels = Keyword.get_values(opts, :label)
    {:ok, hello} = Host.hello(labels: labels, capacity: opts[:capacity])

    Output.info("Pedindo acesso a #{url} para #{hello.hostname}...")

    case DeviceLogin.run(String.trim_trailing(url, "/"), hello,
           name: opts[:name],
           on_code: &show_code/1
         ) do
      {:ok, result} ->
        result
        |> Map.merge(%{
          url: String.trim_trailing(url, "/"),
          labels: labels,
          capacity: opts[:capacity],
          root: nil
        })
        |> Config.save()

        Output.info("""

        Runner "#{result.runner_name}" conectado ao workspace #{result.workspace_name}.
        Credenciais salvas em #{Config.path()}.
        Para ficar online: pipemaestro start --root ~/src (ou make runner.start ROOT=~/src)
        """)

      {:error, :denied} ->
        Output.fail!("O pedido foi recusado na plataforma.")

      {:error, :expired} ->
        Output.fail!("O código expirou antes de ser aprovado. Rode o login de novo.")

      {:error, {:unreachable, exception}} ->
        Output.fail!("Não foi possível falar com #{url}: #{Exception.message(exception)}")

      {:error, {:unexpected, detail}} ->
        Output.fail!("Resposta inesperada da plataforma: #{inspect(detail)}")
    end
  end

  defp show_code(code) do
    Output.info("""

    Abra #{code.verification_uri}
    e digite o código:  #{code.user_code}

    Ou acesse direto: #{code.verification_uri_complete}

    Aguardando aprovação (o código vale #{div(code.expires_in, 60)} minutos)...
    """)
  end
end
