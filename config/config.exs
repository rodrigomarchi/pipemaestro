# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

# Configure Mix tasks and generators
config :pipe_maestro,
  ecto_repos: [PipeMaestro.Repo],
  generators: [binary_id: true, timestamp_type: :utc_datetime]

config :pipe_maestro_web,
  ecto_repos: [PipeMaestro.Repo],
  generators: [context_app: :pipe_maestro, binary_id: true]

# Configures the endpoint
config :pipe_maestro_web, PipeMaestroWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PipeMaestroWeb.ErrorHTML, json: PipeMaestroWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: PipeMaestro.PubSub,
  live_view: [signing_salt: "7xB16y0O"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  pipe_maestro_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/pipe_maestro_web/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  pipe_maestro_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/pipe_maestro_web", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Form field errors go through the app's translator (Portuguese, safe bindings)
config :petal_components,
       :error_translator_function,
       {PipeMaestroWeb.ErrorHelpers, :translate_error}

# Elixir's own JSON (1.18+) for Phoenix, as everywhere in our code
config :phoenix, :json_library, JSON

# And for the jsonb columns: Postgrex defaults to Jason, which the domain no
# longer depends on. Read when Postgrex compiles (mix deps.compile postgrex).
config :postgrex, :json_library, JSON

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"
