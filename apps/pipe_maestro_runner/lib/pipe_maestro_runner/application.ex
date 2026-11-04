defmodule PipeMaestroRunner.Application do
  @moduledoc false

  use Application

  alias PipeMaestroRunner.Main

  @impl true
  def start(_type, _args) do
    standalone(System.get_env())
    Supervisor.start_link([], strategy: :one_for_one, name: PipeMaestroRunner.Supervisor)
  end

  @doc """
  In the single binary (Burrito sets `__BURRITO`), the release boots instead
  of `eval`, and Elixir's CLI would then read the arguments as scripts: so the
  command in them (`PipeMaestroRunner.Main.run/1`) runs here, while the
  runner starts, and the VM halts with its status. Only the release's own VM
  does it (its `RELEASE_ROOT` is the code's root dir): a VM that merely
  inherited the variables, such as a `mix test` a gate started, runs nothing.
  Anywhere else, nothing.
  """
  @spec standalone(%{String.t() => String.t()}, keyword()) :: :not_standalone | no_return()
  def standalone(env, opts \\ []) do
    root_dir = Keyword.get(opts, :root_dir, fn -> to_string(:code.root_dir()) end)

    if Map.has_key?(env, "__BURRITO") and Map.get(env, "RELEASE_ROOT") == root_dir.() do
      argv = Keyword.get(opts, :argv, &:init.get_plain_arguments/0)
      run = Keyword.get(opts, :run, &Main.run/1)
      halt = Keyword.get(opts, :halt, &System.halt/1)
      argv.() |> Enum.map(&to_string/1) |> run.() |> halt.()
    else
      :not_standalone
    end
  end
end
