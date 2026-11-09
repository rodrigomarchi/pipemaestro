defmodule PipeMaestro.Workspaces.Workspace do
  @moduledoc """
  A customer company: the tenant every pipeline, runner and user belongs to.
  `max_running_tasks` caps how many of its tasks run at once (none when
  `nil`); past it, new tasks wait in line (`PipeMaestro.Tasks`).
  `runner_log_retention_days` is how long its runners' log lines are kept
  (`PipeMaestro.RunnerTelemetry`); 0 keeps none, only their events.

  Its retention of what the agent left (ADR 0053), applied by
  `PipeMaestro.Maintenance`:

    * `job_files_retention_days`: after how many days a job's file loses its
      content (`nil`, the default: never);
    * `job_files_quota_mib`: how much its files that still have content may
      take, in MiB (`nil`, the default: no quota); past it, a runner's upload
      is refused (`PipeMaestro.Jobs.Files`);
    * `agent_events_retention_days`: how many days the events of a job that
      ended stay whole (default 30);
    * `agent_events_after_retention`: what then happens to them, `:metadata`
      (the default: each keeps only its metadata) or `:delete`.
  """
  use PipeMaestro.Schema

  import Ecto.Changeset

  alias PipeMaestro.Accounts.User
  alias PipeMaestro.Workspaces.Membership

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          slug: String.t() | nil,
          member_count: non_neg_integer() | nil,
          max_running_tasks: pos_integer() | nil,
          runner_log_retention_days: non_neg_integer(),
          job_files_retention_days: pos_integer() | nil,
          job_files_quota_mib: pos_integer() | nil,
          agent_events_retention_days: pos_integer(),
          agent_events_after_retention: :metadata | :delete,
          users: [User.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "workspaces" do
    field :name, :string
    field :slug, :string
    field :member_count, :integer, virtual: true
    field :max_running_tasks, :integer
    field :runner_log_retention_days, :integer, default: 7
    field :job_files_retention_days, :integer
    field :job_files_quota_mib, :integer
    field :agent_events_retention_days, :integer, default: 30

    field :agent_events_after_retention, Ecto.Enum,
      values: [:metadata, :delete],
      default: :metadata

    has_many :memberships, Membership
    many_to_many :users, User, join_through: Membership

    timestamps()
  end

  @doc """
  Changeset for creating or editing a workspace. Without a slug, one is derived
  from the name.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [
      :name,
      :slug,
      :max_running_tasks,
      :runner_log_retention_days,
      :job_files_retention_days,
      :job_files_quota_mib,
      :agent_events_retention_days,
      :agent_events_after_retention
    ])
    |> validate_number(:max_running_tasks, greater_than: 0, message: "use um número positivo")
    |> validate_required([:runner_log_retention_days])
    |> validate_number(:runner_log_retention_days,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 90,
      message: "use de 0 a 90 dias"
    )
    |> validate_number(:job_files_retention_days,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 3650,
      message: "use de 1 a 3650 dias"
    )
    |> validate_number(:job_files_quota_mib,
      greater_than: 0,
      less_than_or_equal_to: 1_048_576,
      message: "use um número positivo"
    )
    |> after_retention_message()
    |> validate_required([:agent_events_retention_days, :agent_events_after_retention],
      message: "não pode ficar em branco"
    )
    |> validate_number(:agent_events_retention_days,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 3650,
      message: "use de 1 a 3650 dias"
    )
    |> validate_required([:name])
    |> validate_length(:name, max: 80)
    |> put_default_slug()
    |> validate_required([:slug])
    |> validate_length(:slug, min: 2, max: 40)
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
      message: "use letras minúsculas, números e hífens"
    )
    |> unsafe_validate_unique(:slug, PipeMaestro.Repo, message: "já está em uso")
    |> unique_constraint(:slug, message: "já está em uso")
  end

  @doc ~S"""
  A URL slug for `name`: ASCII, lowercase, words joined by hyphens.

      iex> PipeMaestro.Workspaces.Workspace.slugify("Acme Engenharia & Cia")
      "acme-engenharia-cia"
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(name) do
    name
    |> String.normalize(:nfd)
    |> String.replace(~r/[^A-Za-z0-9\s-]/u, "")
    |> String.downcase()
    |> String.split(~r/[\s-]+/, trim: true)
    |> Enum.join("-")
  end

  # A value out of `:metadata` and `:delete` fails the cast; its message says
  # what to choose.
  defp after_retention_message(changeset) do
    errors =
      Enum.map(changeset.errors, fn
        {:agent_events_after_retention, {_message, opts}} ->
          {:agent_events_after_retention, {"escolha manter só os metadados ou apagar", opts}}

        error ->
          error
      end)

    %{changeset | errors: errors}
  end

  defp put_default_slug(changeset) do
    case {get_field(changeset, :slug), get_change(changeset, :name)} do
      {slug, name} when slug in [nil, ""] and is_binary(name) ->
        put_change(changeset, :slug, slugify(name))

      _ ->
        changeset
    end
  end
end
