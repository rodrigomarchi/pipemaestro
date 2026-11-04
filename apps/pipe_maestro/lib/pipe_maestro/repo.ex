defmodule PipeMaestro.Repo do
  use Ecto.Repo,
    otp_app: :pipe_maestro,
    adapter: Ecto.Adapters.Postgres
end
