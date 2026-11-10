import Config

# Tests run the housekeeping themselves.
config :pipe_maestro, PipeMaestro.Maintenance, false

# Tests run the integrations' reconciliation themselves.
config :pipe_maestro, PipeMaestro.Integrations.Reconciler, false

# The git hosts answer from PipeMaestro.FakeForgejo, through Req.Test.
config :pipe_maestro, PipeMaestro.Integrations,
  req_options: [plug: {Req.Test, PipeMaestro.Integrations}, retry: false],
  public_url: "https://pm.test",
  allow_private_hosts: true

# The platform's GitHub App, against the fake GitHub (PipeMaestro.FakeGitHub).
github_key = :public_key.generate_key({:rsa, 2048, 65_537})

config :pipe_maestro, PipeMaestro.Integrations.GitHub,
  app_id: "4242",
  slug: "pipemaestro-test",
  client_id: "Iv1.teste",
  client_secret: "segredo-do-cliente",
  private_key: :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, github_key)]),
  webhook_secret: "segredo-do-app",
  api_url: "https://api.github.test",
  web_url: "https://github.test"

# Tests reflect a task on its source themselves (PipeMaestro.TaskSources).
config :pipe_maestro, PipeMaestro.TaskSources.Dispatcher, false

# Tests look at a task's pull request themselves (PipeMaestro.Integrations.AutoMerge).
config :pipe_maestro, PipeMaestro.Integrations.AutoMergeWorker, false

# A git worktree gets its own database (config/worktree.exs);
# MIX_TEST_PARTITION splits it further (`mix help test`).
{worktree, _binding} = Code.eval_file("worktree.exs", __DIR__)

config :pipe_maestro, PipeMaestro.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("TEST_DB_PORT", "5443")),
  database: "pipe_maestro_test#{worktree}#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  # A test's processes share its one sandbox connection: one waits while
  # another holds it in a transaction (a row lock around a call to a fake
  # host), longer on a machine busy with other suites than the default
  # queue allows.
  queue_target: 2_000,
  queue_interval: 5_000

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :pipe_maestro_web, PipeMaestroWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "l3h40YKVIP2FgWuxJ6mOtdzYm9iDr1wPd/Xk7ZpvZzGJ4tDU2o3tfANRazex433C",
  server: false

# Only for tests: a low cost factor keeps password hashing fast
config :bcrypt_elixir, log_rounds: 4

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Fixed versions, the control plane's and the runner's it requires, so the
# runners' "outdated" badge does not depend on the git state of the checkout
# running the tests. They differ, as they do when a deploy leaves the runner be.
config :pipe_maestro, PipeMaestro.Version,
  version: "2026-11-04.02",
  runner_version: "2026-11-03.02"

# Fixture runners announce made-up versions; the tests of the rule turn it on.
config :pipe_maestro, :runner_version_policy, :off

# Encrypts the workspaces' secrets at rest; production reads SECRETS_KEY.
config :pipe_maestro, PipeMaestro.Secrets, key: "test_only_secrets_key"
