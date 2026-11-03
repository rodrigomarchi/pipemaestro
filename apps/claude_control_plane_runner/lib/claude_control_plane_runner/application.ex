defmodule ClaudeControlPlaneRunner.Application do
  @moduledoc false

  use Application

  alias ClaudeControlPlaneRunner.Main

  @impl true
  def start(_type, _args) do
    standalone(System.get_env())
    Supervisor.start_link([], strategy: :one_for_one, name: ClaudeControlPlaneRunner.Supervisor)
  end

  @doc """
  In the single binary (Burrito sets `__BURRITO`), the release boots instead
  of `eval`, and Elixir's CLI would then read the arguments as scripts: so the
  command in them (`ClaudeControlPlaneRunner.Main.run/1`) runs here, while the
  runner starts, and the VM halts with its status. Anywhere else, nothing.
  """
  @spec standalone(%{String.t() => String.t()}, keyword()) :: :not_standalone | no_return()
  def standalone(env, opts \\ []) do
    if Map.has_key?(env, "__BURRITO") do
      argv = Keyword.get(opts, :argv, &:init.get_plain_arguments/0)
      run = Keyword.get(opts, :run, &Main.run/1)
      halt = Keyword.get(opts, :halt, &System.halt/1)
      argv.() |> Enum.map(&to_string/1) |> run.() |> halt.()
    else
      :not_standalone
    end
  end
end
