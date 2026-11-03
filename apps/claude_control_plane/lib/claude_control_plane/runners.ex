defmodule ClaudeControlPlane.Runners do
  @moduledoc """
  Runners: the daemons customers install, how they sign in (a device flow that
  a workspace member approves in the browser), and what the control plane
  knows about them.

  A runner never holds a user's credentials. It gets a token of its own when
  its sign-in is approved; the control plane keeps only that token's hash, and
  revoking the runner discards it.
  """

  import Ecto.Query

  alias ClaudeControlPlane.Accounts.User
  alias ClaudeControlPlane.Auth.Token
  alias ClaudeControlPlane.Repo
  alias ClaudeControlPlane.Runners.{DeviceAuthorization, Runner}
  alias ClaudeControlPlane.Workspaces
  alias ClaudeControlPlane.Workspaces.Workspace
  alias ClaudeControlPlaneProtocol.Hello

  @authorization_ttl_seconds 600
  @poll_interval_seconds 5
  @token_prefix "cpr_"

  # Consonants only: no vowel means no accidental word, and none of them is
  # easy to mistake for a digit.
  @user_code_alphabet ~c"BCDFGHJKLMNPQRSTVWXZ"
  @user_code_length 8

  @doc "Seconds a device authorization stays valid."
  @spec authorization_ttl_seconds() :: pos_integer()
  def authorization_ttl_seconds, do: @authorization_ttl_seconds

  @doc "Seconds a runner must wait between two polls."
  @spec poll_interval_seconds() :: pos_integer()
  def poll_interval_seconds, do: @poll_interval_seconds

  # ── Device flow ───────────────────────────────────────────────────────────

  @doc """
  Starts a runner's sign-in. Returns the authorization, the secret device code
  the runner polls with, and the user code a person types in the browser.
  """
  @spec start_device_authorization(Hello.t(), String.t() | nil) ::
          {:ok, DeviceAuthorization.t(), String.t(), String.t()}
  def start_device_authorization(%Hello{} = hello, requested_name \\ nil) do
    {device_code, device_code_hash} = random_token()
    user_code = generate_user_code()
    name = present(requested_name) || hello.hostname

    authorization =
      Repo.insert!(%DeviceAuthorization{
        device_code_hash: device_code_hash,
        user_code: user_code,
        requested: Hello.to_map(hello),
        name: String.slice(name, 0, 80),
        expires_at: DateTime.add(now(), @authorization_ttl_seconds)
      })

    {:ok, authorization, device_code, format_user_code(user_code)}
  end

  @doc """
  The pending, unexpired authorization for a user code as typed by a person:
  case, spaces and the hyphen do not matter.
  """
  @spec get_pending_authorization(String.t()) :: DeviceAuthorization.t() | nil
  def get_pending_authorization(user_code) when is_binary(user_code) do
    code = normalize_user_code(user_code)

    if String.length(code) == @user_code_length do
      Repo.one(
        from a in DeviceAuthorization,
          where: a.user_code == ^code and a.status == :pending and a.expires_at > ^now()
      )
    end
  end

  @doc """
  Approves a sign-in into `workspace`, which `user` must belong to, creating
  the runner under `name`. The runner's token is issued later, when the runner
  polls (`exchange_device_code/1`).
  """
  @spec approve_device_authorization(DeviceAuthorization.t(), User.t(), Workspace.t(), String.t()) ::
          {:ok, Runner.t()} | {:error, :not_a_member | :not_pending | Ecto.Changeset.t()}
  def approve_device_authorization(%DeviceAuthorization{} = auth, %User{} = user, workspace, name) do
    cond do
      not Workspaces.member?(workspace, user) -> {:error, :not_a_member}
      not pending?(auth) -> {:error, :not_pending}
      true -> do_approve(auth, user, workspace, name)
    end
  end

  defp do_approve(auth, user, workspace, name) do
    requested = auth.requested

    Repo.transact(fn ->
      runner_changeset =
        %Runner{
          workspace_id: workspace.id,
          approved_by_user_id: user.id,
          hostname: requested["hostname"],
          os: requested["os"],
          arch: requested["arch"],
          runner_version: requested["runner_version"],
          labels: requested["labels"] || [],
          capacity: requested["capacity"] || 1
        }
        |> Runner.name_changeset(%{name: name})

      with {:ok, runner} <- Repo.insert(runner_changeset),
           {:ok, _auth} <-
             auth
             |> Ecto.Changeset.change(
               status: :approved,
               workspace_id: workspace.id,
               approved_by_user_id: user.id,
               runner_id: runner.id,
               name: runner.name
             )
             |> Repo.update() do
        {:ok, runner}
      end
    end)
  end

  @doc "Refuses a sign-in. The runner's next poll gets `:access_denied`."
  @spec deny_device_authorization(DeviceAuthorization.t()) ::
          {:ok, DeviceAuthorization.t()} | {:error, :not_pending}
  def deny_device_authorization(%DeviceAuthorization{} = auth) do
    if pending?(auth),
      do: auth |> Ecto.Changeset.change(status: :denied) |> Repo.update(),
      else: {:error, :not_pending}
  end

  @doc """
  What a polling runner gets for its device code: its token once the sign-in
  was approved, or why not yet. A code yields a token only once.
  """
  @spec exchange_device_code(String.t()) ::
          {:ok, Runner.t(), String.t()} | {:error, ClaudeControlPlaneProtocol.device_error()}
  def exchange_device_code(device_code) when is_binary(device_code) do
    case Repo.get_by(DeviceAuthorization, device_code_hash: Token.hash(device_code)) do
      nil -> {:error, :invalid_request}
      auth -> exchange(auth, now())
    end
  end

  defp exchange(%DeviceAuthorization{status: :consumed}, _now), do: {:error, :invalid_request}
  defp exchange(%DeviceAuthorization{status: :denied}, _now), do: {:error, :access_denied}

  defp exchange(%DeviceAuthorization{status: :approved} = auth, _now) do
    Repo.transact(fn ->
      runner = Repo.get!(Runner, auth.runner_id)
      {token, token_hash} = runner_token()

      {:ok, runner} = runner |> Ecto.Changeset.change(token_hash: token_hash) |> Repo.update()
      {:ok, _auth} = auth |> Ecto.Changeset.change(status: :consumed) |> Repo.update()

      {:ok, {runner, token}}
    end)
    |> case do
      {:ok, {runner, token}} -> {:ok, runner, token}
    end
  end

  defp exchange(%DeviceAuthorization{status: :pending} = auth, now) do
    cond do
      DateTime.compare(auth.expires_at, now) != :gt ->
        {:error, :expired_token}

      auth.last_polled_at && DateTime.diff(now, auth.last_polled_at) < @poll_interval_seconds ->
        touch_poll(auth, now)
        {:error, :slow_down}

      true ->
        touch_poll(auth, now)
        {:error, :authorization_pending}
    end
  end

  defp touch_poll(auth, now) do
    auth |> Ecto.Changeset.change(last_polled_at: now) |> Repo.update!()
  end

  # ── Runners ───────────────────────────────────────────────────────────────

  @doc "The runner holding `token`, unless it was revoked."
  @spec authenticate_runner(String.t()) :: Runner.t() | nil
  def authenticate_runner(@token_prefix <> _ = token) do
    Repo.one(
      from r in Runner,
        where: r.token_hash == ^Token.hash(token) and is_nil(r.revoked_at),
        preload: [:workspace]
    )
  end

  def authenticate_runner(_token), do: nil

  @doc "The runners of `workspace` that were not revoked, by name."
  @spec list_runners(Workspace.t()) :: [Runner.t()]
  def list_runners(%Workspace{id: workspace_id}) do
    Repo.all(
      from r in Runner,
        where: r.workspace_id == ^workspace_id and is_nil(r.revoked_at),
        order_by: [asc: r.name]
    )
  end

  @doc "A runner of `workspace`. Raises when it is not there or was revoked."
  @spec get_runner!(Workspace.t(), Ecto.UUID.t()) :: Runner.t()
  def get_runner!(%Workspace{id: workspace_id}, id) do
    Repo.one!(
      from r in Runner,
        where: r.id == ^id and r.workspace_id == ^workspace_id and is_nil(r.revoked_at)
    )
  end

  @doc "Stores what a runner announced as it connected."
  @spec record_hello(Runner.t(), Hello.t()) :: {:ok, Runner.t()}
  def record_hello(%Runner{} = runner, %Hello{} = hello) do
    runner |> Runner.hello_changeset(hello, now()) |> Repo.update()
  end

  @doc "Notes that the runner was just seen (for \"last seen\" after it goes offline)."
  @spec touch_last_seen(Runner.t()) :: :ok
  def touch_last_seen(%Runner{id: id}) do
    Repo.update_all(from(r in Runner, where: r.id == ^id), set: [last_seen_at: now()])
    :ok
  end

  @doc "A changeset for the rename form."
  @spec change_runner_name(Runner.t(), map()) :: Ecto.Changeset.t()
  def change_runner_name(%Runner{} = runner, attrs \\ %{}),
    do: Runner.name_changeset(runner, attrs)

  @doc "Renames a runner."
  @spec rename_runner(Runner.t(), map()) :: {:ok, Runner.t()} | {:error, Ecto.Changeset.t()}
  def rename_runner(%Runner{} = runner, attrs),
    do: runner |> Runner.name_changeset(attrs) |> Repo.update()

  @doc """
  Revokes a runner: its token stops working at once. The caller is expected
  to close the runner's open connection.
  """
  @spec revoke_runner(Runner.t()) :: {:ok, Runner.t()}
  def revoke_runner(%Runner{} = runner) do
    runner
    |> Ecto.Changeset.change(revoked_at: now(), token_hash: nil)
    |> Repo.update()
  end

  @doc "Formats a stored user code for display: `WDJBMJHT` becomes `WDJB-MJHT`."
  @spec format_user_code(String.t()) :: String.t()
  def format_user_code(code) do
    {first, second} = String.split_at(code, div(@user_code_length, 2))
    first <> "-" <> second
  end

  defp pending?(%DeviceAuthorization{status: :pending, expires_at: expires_at}),
    do: DateTime.compare(expires_at, now()) == :gt

  defp pending?(_auth), do: false

  defp normalize_user_code(code), do: code |> String.upcase() |> String.replace(~r/[^A-Z]/, "")

  defp generate_user_code do
    for _ <- 1..@user_code_length, into: "", do: <<Enum.random(@user_code_alphabet)>>
  end

  defp random_token do
    raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    {raw, Token.hash(raw)}
  end

  defp runner_token do
    {raw, _hash} = random_token()
    token = @token_prefix <> raw
    {token, Token.hash(token)}
  end

  defp present(nil), do: nil
  defp present(text), do: if(String.trim(text) == "", do: nil, else: String.trim(text))

  defp now, do: DateTime.utc_now(:second)
end
