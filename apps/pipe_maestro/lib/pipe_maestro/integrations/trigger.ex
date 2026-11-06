defmodule PipeMaestro.Integrations.Trigger do
  @moduledoc """
  What starts a task from an issue of a linked repository
  (`docs/specs/integracoes.md`, section 3):

  - `kind`: `"label"` (the `label` was added), `"comment"` (a comment starts
    with the `command`) or `"opened"` (a new issue).
  - `mode`: `"triage"` has the agent write the task (`PipeMaestro.Proposals`),
    created on its own with `auto_approve`; `"task"` starts the `pipeline`
    with the issue's text.
  - `author_policy`: `"writers"` (whoever has write access to the repository)
    or `"anyone"`, which a comment or a new issue must confirm
    (`confirm_anyone`) and only with a triage: the issue's text goes into the
    agent's prompt.
  - `max_per_hour`: how many times it may fire in an hour.
  - `acting_user`: on whose behalf the task is created.

  With the runner calling the host (`api_mode` `"runner"`), only a label
  triggers: the other kinds need the API to check who wrote the issue, and
  adding a label already takes write access.
  """
  use PipeMaestro.Schema

  import Ecto.Changeset

  alias PipeMaestro.Integrations.LinkedRepo

  @kinds ~w(label comment opened)
  @modes ~w(triage task)
  @author_policies ~w(writers anyone)

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          kind: String.t() | nil,
          label: String.t() | nil,
          command: String.t() | nil,
          mode: String.t(),
          auto_approve: boolean(),
          pipeline_id: Ecto.UUID.t() | nil,
          author_policy: String.t(),
          confirm_anyone: boolean() | nil,
          max_per_hour: pos_integer(),
          acting_user_id: Ecto.UUID.t() | nil,
          enabled: boolean(),
          workspace_id: Ecto.UUID.t() | nil,
          repo_id: Ecto.UUID.t() | nil,
          repo: LinkedRepo.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "integration_triggers" do
    field :kind, :string
    field :label, :string
    field :command, :string
    field :mode, :string, default: "triage"
    field :auto_approve, :boolean, default: true
    field :pipeline_id, :binary_id
    field :author_policy, :string, default: "writers"
    field :confirm_anyone, :boolean, virtual: true
    field :max_per_hour, :integer, default: 10
    field :acting_user_id, :binary_id
    field :enabled, :boolean, default: true
    field :workspace_id, :binary_id

    belongs_to :repo, LinkedRepo

    timestamps()
  end

  @doc "The kinds of trigger."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The kinds a connection in `api_mode` accepts."
  @spec kinds(String.t()) :: [String.t()]
  def kinds("runner"), do: ["label"]
  def kinds(_api_mode), do: @kinds

  @doc "Changeset for a trigger of a connection in `api_mode`."
  @spec changeset(t(), map(), String.t()) :: Ecto.Changeset.t()
  def changeset(trigger, attrs, api_mode) do
    trigger
    |> cast(attrs, [
      :kind,
      :label,
      :command,
      :mode,
      :auto_approve,
      :pipeline_id,
      :author_policy,
      :confirm_anyone,
      :max_per_hour,
      :acting_user_id,
      :enabled
    ])
    |> validate_required([:kind], message: "escolha o gatilho")
    |> validate_inclusion(:kind, kinds(api_mode),
      message: "com o runner chamando o host, só a label dispara"
    )
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:author_policy, @author_policies)
    |> validate_number(:max_per_hour,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 100,
      message: "use de 1 a 100"
    )
    |> validate_by_kind()
    |> validate_pipeline()
    |> validate_anyone()
  end

  defp validate_by_kind(changeset) do
    case get_field(changeset, :kind) do
      "label" ->
        changeset
        |> update_change(:label, &String.trim/1)
        |> validate_required([:label], message: "informe a label")
        |> validate_length(:label, max: 50)

      "comment" ->
        changeset
        |> update_change(:command, &String.trim/1)
        |> validate_required([:command], message: "informe o comando")
        |> validate_format(:command, ~r/^\/[\w.-]{1,30}$/, message: "use /comando, sem espaços")

      _other ->
        changeset
    end
  end

  defp validate_pipeline(changeset) do
    if get_field(changeset, :mode) == "task",
      do:
        validate_required(changeset, [:pipeline_id],
          message: "a tarefa direta precisa do pipeline"
        ),
      else: changeset
  end

  # Any author's text goes only to a triage, which runs apart, without the
  # workspace's secrets nor the git credential; a task would carry both.
  defp validate_anyone(changeset) do
    anyone? =
      get_field(changeset, :author_policy) == "anyone" and
        get_field(changeset, :kind) in ~w(comment opened)

    if anyone? and get_field(changeset, :mode) == "task",
      do: add_error(changeset, :mode, "com qualquer autor, use a triagem com IA"),
      else: confirm_anyone(changeset)
  end

  defp confirm_anyone(changeset) do
    if get_field(changeset, :author_policy) == "anyone" and
         get_field(changeset, :kind) in ~w(comment opened) and
         get_change(changeset, :author_policy) != nil and
         get_field(changeset, :confirm_anyone) != true,
       do:
         add_error(
           changeset,
           :confirm_anyone,
           "confirme: o texto de qualquer pessoa entra no prompt do agente"
         ),
       else: changeset
  end
end
