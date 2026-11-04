import Config

# Tests run the housekeeping themselves.
config :claude_control_plane, ClaudeControlPlane.Maintenance, false

# A git worktree gets its own database (config/worktree.exs);
# MIX_TEST_PARTITION splits it further (`mix help test`).
{worktree, _binding} = Code.eval_file("worktree.exs", __DIR__)

config :claude_control_plane, ClaudeControlPlane.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("TEST_DB_PORT", "5443")),
  database: "claude_control_plane_test#{worktree}#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :claude_control_plane_web, ClaudeControlPlaneWeb.Endpoint,
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

# Encrypts the workspaces' secrets at rest; production reads SECRETS_KEY.
config :claude_control_plane, ClaudeControlPlane.Secrets, key: "test_only_secrets_key"
