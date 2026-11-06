defmodule PipeMaestro.Fixtures do
  @moduledoc "Records for tests: users, operators and workspaces with valid defaults."

  alias PipeMaestro.{Accounts, Backoffice, Workspaces}

  @doc "A password that passes every rule."
  @spec valid_password() :: String.t()
  def valid_password, do: "uma senha bem longa"

  @doc "A unique e-mail."
  @spec unique_email() :: String.t()
  def unique_email, do: "pessoa#{System.unique_integer([:positive])}@example.com"

  @doc "A created user."
  @spec user_fixture(map()) :: Accounts.User.t()
  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{email: unique_email(), name: "Pessoa Teste", password: valid_password()})
      |> Accounts.create_user()

    user
  end

  @doc "A created operator."
  @spec operator_fixture(map()) :: Backoffice.Operator.t()
  def operator_fixture(attrs \\ %{}) do
    {:ok, operator} =
      attrs
      |> Enum.into(%{email: unique_email(), name: "Operador Teste", password: valid_password()})
      |> Backoffice.create_operator()

    operator
  end

  @doc "A created workspace."
  @spec workspace_fixture(map()) :: Workspaces.Workspace.t()
  def workspace_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, workspace} =
      attrs
      |> Enum.into(%{name: "Empresa #{n}", slug: "empresa-#{n}"})
      |> Workspaces.create_workspace()

    workspace
  end

  @doc "A user who belongs to `workspace`, with `role` (the first one is the admin)."
  @spec member_fixture(Workspaces.Workspace.t(), map(), atom() | nil) :: Accounts.User.t()
  def member_fixture(workspace, attrs \\ %{}, role \\ nil) do
    user = user_fixture(attrs)
    {:ok, _membership} = Workspaces.add_member(workspace, user, role)
    user
  end

  @doc "A valid runner announcement."
  @spec hello_fixture(map()) :: PipeMaestroProtocol.Hello.t()
  def hello_fixture(attrs \\ %{}) do
    {:ok, hello} =
      attrs
      |> Enum.into(%{
        protocol_version: PipeMaestroProtocol.version(),
        runner_version: "0.1.0",
        hostname: "build-#{System.unique_integer([:positive])}",
        os: "linux",
        arch: "x86_64",
        labels: ["linux", "elixir"],
        capacity: 4
      })
      |> PipeMaestroProtocol.Hello.new()

    hello
  end

  @doc """
  A runner signed in to `workspace` through the whole device flow, approved by
  `user` (a member). Returns the runner and its token.
  """
  @spec runner_fixture(Workspaces.Workspace.t(), Accounts.User.t(), map()) ::
          {PipeMaestro.Runners.Runner.t(), String.t()}
  def runner_fixture(workspace, user, attrs \\ %{}) do
    alias PipeMaestro.Runners

    hello = hello_fixture(Map.drop(attrs, [:name]))
    {:ok, auth, device_code, _user_code} = Runners.start_device_authorization(hello)
    name = Map.get(attrs, :name, hello.hostname)
    {:ok, _runner} = Runners.approve_device_authorization(auth, user, workspace, name)
    {:ok, runner, token} = Runners.exchange_device_code(device_code)
    {runner, token}
  end

  @doc "`runner` after announcing `directories` (maps with a name and a git flag)."
  @spec with_directories(PipeMaestro.Runners.Runner.t(), [map()]) ::
          PipeMaestro.Runners.Runner.t()
  def with_directories(runner, directories) do
    {:ok, runner} =
      PipeMaestro.Runners.record_hello(runner, hello_fixture(%{directories: directories}))

    runner
  end

  @doc """
  A project of `runner`'s workspace on `runner`'s `directory` (which the
  runner must offer), named after the directory unless `attrs` says.
  """
  @spec project_fixture(PipeMaestro.Runners.Runner.t(), String.t(), map()) ::
          PipeMaestro.Projects.Project.t()
  def project_fixture(runner, directory, attrs \\ %{}) do
    workspace = PipeMaestro.Repo.get!(Workspaces.Workspace, runner.workspace_id)

    {:ok, project} =
      PipeMaestro.Projects.create_project(
        workspace,
        Enum.into(attrs, %{
          "name" => directory,
          "runner_id" => runner.id,
          "directory" => directory
        })
      )

    project
  end

  @doc """
  The project of `runner`'s `directory`: the one already there, or a new one
  (`project_fixture/3`).
  """
  @spec project_on(PipeMaestro.Runners.Runner.t(), String.t()) ::
          PipeMaestro.Projects.Project.t()
  def project_on(runner, directory) do
    PipeMaestro.Repo.get_by(PipeMaestro.Projects.Project,
      runner_id: runner.id,
      directory: directory
    ) || project_fixture(runner, directory)
  end

  @doc """
  The projects of `runner` for each of the directories it offers, by
  directory name.
  """
  @spec projects_fixture(PipeMaestro.Runners.Runner.t()) :: %{
          String.t() => PipeMaestro.Projects.Project.t()
        }
  def projects_fixture(runner) do
    Map.new(runner.directories, &{&1["name"], project_fixture(runner, &1["name"])})
  end

  @doc "A pipeline of `workspace`; by default two stages, `a` and `b`."
  @spec pipeline_fixture(Workspaces.Workspace.t(), map()) ::
          PipeMaestro.Pipelines.Pipeline.t()
  def pipeline_fixture(workspace, attrs \\ %{}) do
    {:ok, pipeline} =
      PipeMaestro.Pipelines.create_pipeline(
        workspace,
        Enum.into(attrs, %{
          "name" => "Pipeline #{System.unique_integer([:positive])}",
          "stages" => [
            %{"key" => "a", "name" => "Etapa A", "prompt" => "Faça A: {{tarefa.descricao}}"},
            %{"key" => "b", "name" => "Etapa B", "prompt" => "Faça B"}
          ]
        })
      )

    pipeline
  end

  @doc "A job `user` sent to `runner` (both of `runner`'s workspace), still queued."
  @spec job_fixture(PipeMaestro.Runners.Runner.t(), Accounts.User.t(), map()) ::
          PipeMaestro.Jobs.Job.t()
  def job_fixture(runner, user, attrs \\ %{}) do
    workspace = PipeMaestro.Repo.get!(Workspaces.Workspace, runner.workspace_id)

    {:ok, job} =
      PipeMaestro.Jobs.create_runner_job(
        user,
        workspace,
        Enum.into(attrs, %{"prompt" => "diga oi", "runner_id" => runner.id})
      )

    job
  end

  @doc """
  A connection of `workspace` to the fake Forgejo (`PipeMaestro.FakeForgejo`),
  by token, active as its bot.
  """
  @spec connection_fixture(Workspaces.Workspace.t(), map()) ::
          PipeMaestro.Integrations.Connection.t()
  def connection_fixture(workspace, attrs \\ %{}) do
    alias PipeMaestro.Integrations.Connection

    %Connection{workspace_id: workspace.id}
    |> Connection.changeset(
      Enum.into(attrs, %{
        "name" => "Forgejo #{System.unique_integer([:positive])}",
        "provider" => "forgejo",
        "base_url" => PipeMaestro.FakeForgejo.base_url(),
        "auth_kind" => "token",
        "token" => "tok"
      })
    )
    |> Ecto.Changeset.change(status: "active", bot_login: "pipemaestro-bot", bot_user_id: "7")
    |> PipeMaestro.Repo.insert!()
  end

  @doc """
  A project `app` of `workspace` on a runner of its own, `app-runner`, which
  offers the directory in git and runs disposable worktrees.
  """
  @spec app_project_fixture(Workspaces.Workspace.t(), map()) :: PipeMaestro.Projects.Project.t()
  def app_project_fixture(workspace, attrs \\ %{}) do
    {runner, _token} =
      runner_fixture(workspace, member_fixture(workspace, %{}, :admin), %{
        name: "app-runner-#{System.unique_integer([:positive])}"
      })

    {:ok, runner} =
      PipeMaestro.Runners.record_hello(
        runner,
        hello_fixture(%{
          capabilities: ["git_credential", "health", "scratch"],
          directories: [%{"name" => "app", "git" => true}]
        })
      )

    project_fixture(runner, "app", Enum.into(attrs, %{"name" => "App"}))
  end
end
