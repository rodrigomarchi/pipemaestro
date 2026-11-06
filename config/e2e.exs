import Config

# The browser-driven Playwright suite under top-level e2e/. Like config/test.exs,
# with two differences that matter:
#
#   1. server: true - a real browser has to reach the endpoint.
#   2. No Ecto SQL Sandbox - Playwright and Phoenix are separate processes; a
#      sandbox would hide each one's writes from the other.
#
# A dedicated database keeps the suite from touching dev or test data, and the
# port (E2E_PORT, default 4003) stays clear of dev (4000) and test (4002). A git
# worktree gets its own database (config/worktree.exs) and port (Makefile).
{worktree, _binding} = Code.eval_file("worktree.exs", __DIR__)
e2e_http_port = String.to_integer(System.get_env("E2E_PORT", "4003"))

config :pipe_maestro, PipeMaestro.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("TEST_DB_PORT", "5443")),
  database: "pipe_maestro_e2e#{worktree}",
  pool_size: 10

config :pipe_maestro_web, PipeMaestroWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: e2e_http_port],
  secret_key_base:
    "e2e_only_secret_key_base_not_for_production_run_mix_phx_gen_secret_to_replace_it",
  server: true,
  check_origin: false,
  debug_errors: true

# Quiet by default so Playwright's output stays readable; LOG_LEVEL overrides.
config :logger, level: String.to_atom(System.get_env("LOG_LEVEL", "warning"))

# A low cost factor keeps every sign-in in the suite fast
config :bcrypt_elixir, log_rounds: 4

config :phoenix, :plug_init_mode, :runtime

# As in production, where the deploy publishes the runner's binaries: the
# runners page shows their links (the files themselves are not served here).
config :pipe_maestro_web, :runner_downloads_url, "/downloads/runner"

config :phoenix_live_view, enable_expensive_runtime_checks: true

# Encrypts the workspaces' secrets at rest; production reads SECRETS_KEY.
config :pipe_maestro, PipeMaestro.Secrets, key: "e2e_only_secrets_key"

config :pipe_maestro, PipeMaestro.Integrations, public_url: "http://localhost:#{e2e_http_port}"

# The runner under Mix never updates itself (no single binary, no terminal).
# Here it asks as a single binary in a terminal would (PipeMaestroRunner.Update),
# for a binary that is only a path: the specs answer "no".
config :pipe_maestro_runner, :update_prompt,
  binary: Path.join(System.tmp_dir!(), "pipemaestro-e2e-update")
