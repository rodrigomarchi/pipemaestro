defmodule PipeMaestro.Onboarding do
  @moduledoc """
  The getting-started lesson (ADR 0058): a few screens that show how to connect
  a runner, add a project and pick a pipeline. It is shown to the admins of a
  Free beta workspace that still lacks one of those, once: finishing or
  skipping it ends it for that person in that workspace. Workspaces an
  operator set up (`:custom`) never show it.
  """

  import Ecto.Query

  alias PipeMaestro.Accounts.Scope
  alias PipeMaestro.Pipelines.Pipeline
  alias PipeMaestro.Projects.Project
  alias PipeMaestro.Repo
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.Workspaces.{Membership, Workspace}

  @doc "Whether the person in `scope` should see the lesson in its workspace."
  @spec pending?(Scope.t()) :: boolean()
  def pending?(%Scope{role: :admin, workspace: %Workspace{plan: :free_beta} = workspace} = scope) do
    not seen?(scope) and not set_up?(workspace)
  end

  def pending?(%Scope{}), do: false

  @doc "Ends the lesson for the person in `scope`, in its workspace."
  @spec dismiss(Scope.t()) :: :ok
  def dismiss(%Scope{} = scope) do
    now = DateTime.utc_now(:second)

    scope
    |> membership_query()
    |> where([m], is_nil(m.onboarding_seen_at))
    |> Repo.update_all(set: [onboarding_seen_at: now])

    :ok
  end

  defp seen?(scope) do
    scope |> membership_query() |> where([m], not is_nil(m.onboarding_seen_at)) |> Repo.exists?()
  end

  # A workspace is set up once it has a runner, a project and a pipeline.
  defp set_up?(%Workspace{id: workspace_id}) do
    Repo.exists?(
      from r in Runner, where: r.workspace_id == ^workspace_id and is_nil(r.revoked_at)
    ) and
      Repo.exists?(from p in Project, where: p.workspace_id == ^workspace_id) and
      Repo.exists?(from p in Pipeline, where: p.workspace_id == ^workspace_id)
  end

  defp membership_query(%Scope{user: user, workspace: workspace}) do
    from m in Membership, where: m.workspace_id == ^workspace.id and m.user_id == ^user.id
  end
end
