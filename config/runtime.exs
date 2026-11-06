import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# A release starts the endpoint only when PHX_SERVER is set, so the same
# release can also run one-off commands (migrations, eval) without serving.
if System.get_env("PHX_SERVER") do
  config :pipe_maestro_web, PipeMaestroWeb.Endpoint, server: true
end

# test and e2e fix their own ports in config/{test,e2e}.exs.
if config_env() in [:dev, :prod] do
  config :pipe_maestro_web, PipeMaestroWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :pipe_maestro_web, PipeMaestroWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/pipe_maestro_web/router\.ex$"E,
        ~r"lib/pipe_maestro_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :pipe_maestro, PipeMaestro.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Encrypts the workspaces' secrets at rest (PipeMaestro.Secrets).
  # Changing it makes the stored secrets unreadable.
  config :pipe_maestro, PipeMaestro.Secrets,
    key:
      System.get_env("SECRETS_KEY") ||
        raise("""
        environment variable SECRETS_KEY is missing.
        You can generate one by calling: mix phx.gen.secret
        """)

  host = System.get_env("PHX_HOST") || "example.com"

  # The platform's GitHub App (docs/guias/github-app.md); without it, only
  # Forgejo connects.
  if app_id = System.get_env("GITHUB_APP_ID") do
    config :pipe_maestro, PipeMaestro.Integrations.GitHub,
      app_id: app_id,
      slug: System.fetch_env!("GITHUB_APP_SLUG"),
      client_id: System.fetch_env!("GITHUB_APP_CLIENT_ID"),
      client_secret: System.fetch_env!("GITHUB_APP_CLIENT_SECRET"),
      private_key: System.fetch_env!("GITHUB_APP_PRIVATE_KEY"),
      webhook_secret: System.fetch_env!("GITHUB_APP_WEBHOOK_SECRET"),
      # GitHub Enterprise Server: https://<host>/api/v3 and https://<host>.
      api_url: System.get_env("GITHUB_API_URL", "https://api.github.com"),
      web_url: System.get_env("GITHUB_WEB_URL", "https://github.com")
  end

  # The platform's address in what it writes on a git host (a task's link).
  config :pipe_maestro, PipeMaestro.Integrations,
    public_url: "https://#{host}",
    # A self-hosted platform on the same network as its git host.
    allow_private_hosts: System.get_env("INTEGRATIONS_ALLOW_PRIVATE_HOSTS") == "true"

  config :pipe_maestro_web, PipeMaestroWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :pipe_maestro_web, PipeMaestroWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :pipe_maestro_web, PipeMaestroWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  config :pipe_maestro, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Where this deploy published the runner's binaries (scripts/deploy.sh),
  # e.g. /downloads/runner; the runners page links them. Unset, it does not.
  config :pipe_maestro_web, :runner_downloads_url, System.get_env("RUNNER_DOWNLOADS_URL")
end
