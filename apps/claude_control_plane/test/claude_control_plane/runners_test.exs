defmodule ClaudeControlPlane.RunnersTest do
  use ClaudeControlPlane.DataCase, async: true

  import ClaudeControlPlane.Fixtures

  alias ClaudeControlPlane.Runners
  alias ClaudeControlPlane.Runners.{DeviceAuthorization, Runner}

  setup do
    workspace = workspace_fixture()
    %{workspace: workspace, user: member_fixture(workspace)}
  end

  describe "device flow" do
    test "start, poll, approve, exchange once", %{workspace: workspace, user: user} do
      hello = hello_fixture(%{hostname: "mac-ana"})
      {:ok, auth, device_code, user_code} = Runners.start_device_authorization(hello)

      assert user_code =~ ~r/^[A-Z]{4}-[A-Z]{4}$/
      refute auth.device_code_hash == device_code
      assert auth.name == "mac-ana"

      assert Runners.exchange_device_code(device_code) == {:error, :authorization_pending}
      assert Runners.exchange_device_code(device_code) == {:error, :slow_down}

      pending = Runners.get_pending_authorization(String.downcase(user_code))
      assert pending.id == auth.id

      {:ok, runner} = Runners.approve_device_authorization(pending, user, workspace, "Mac da Ana")
      assert %Runner{name: "Mac da Ana", hostname: "mac-ana", capacity: 4} = runner
      refute Runners.get_pending_authorization(user_code)

      assert {:ok, %Runner{id: id}, "cpr_" <> _ = token} =
               Runners.exchange_device_code(device_code)

      assert id == runner.id
      assert Runners.authenticate_runner(token).id == runner.id
      assert Runners.exchange_device_code(device_code) == {:error, :invalid_request}
    end

    test "the requested name defaults to the hostname but can be set" do
      {:ok, auth, _code, _user_code} =
        Runners.start_device_authorization(hello_fixture(), " Servidor de build ")

      assert auth.name == "Servidor de build"
    end

    test "a denied sign-in answers access_denied", %{user: _user} do
      {:ok, auth, device_code, _user_code} = Runners.start_device_authorization(hello_fixture())
      {:ok, _} = Runners.deny_device_authorization(auth)

      assert Runners.exchange_device_code(device_code) == {:error, :access_denied}
      assert Runners.deny_device_authorization(Repo.reload(auth)) == {:error, :not_pending}
    end

    test "an expired sign-in can no longer be approved or exchanged", %{
      workspace: workspace,
      user: user
    } do
      {:ok, auth, device_code, user_code} = Runners.start_device_authorization(hello_fixture())
      past = DateTime.add(DateTime.utc_now(:second), -1)
      auth = auth |> Ecto.Changeset.change(expires_at: past) |> Repo.update!()

      refute Runners.get_pending_authorization(user_code)
      assert Runners.exchange_device_code(device_code) == {:error, :expired_token}

      assert Runners.approve_device_authorization(auth, user, workspace, "x") ==
               {:error, :not_pending}
    end

    test "only a member can approve into a workspace", %{workspace: workspace} do
      outsider = user_fixture()
      {:ok, auth, _code, _user_code} = Runners.start_device_authorization(hello_fixture())

      assert Runners.approve_device_authorization(auth, outsider, workspace, "x") ==
               {:error, :not_a_member}

      # A member who is not an admin cannot either.
      plain = member_fixture(workspace)

      assert Runners.approve_device_authorization(auth, plain, workspace, "x") ==
               {:error, :not_an_admin}

      assert Repo.reload(auth).status == :pending
    end

    test "an empty name is refused", %{workspace: workspace, user: user} do
      {:ok, auth, _code, _user_code} = Runners.start_device_authorization(hello_fixture())

      assert {:error, %Ecto.Changeset{}} =
               Runners.approve_device_authorization(auth, user, workspace, "  ")

      assert %DeviceAuthorization{status: :pending} = Repo.reload(auth)
    end

    test "unknown codes" do
      assert Runners.exchange_device_code("nope") == {:error, :invalid_request}
      refute Runners.get_pending_authorization("ABC")
      refute Runners.authenticate_runner("cpr_nope")
      refute Runners.authenticate_runner("not-a-runner-token")
    end
  end

  describe "runners" do
    setup %{workspace: workspace, user: user} do
      {runner, token} = runner_fixture(workspace, user, %{name: "build-01"})
      %{runner: runner, token: token}
    end

    test "lists only the workspace's runners", %{workspace: workspace, runner: runner} do
      other = workspace_fixture()
      runner_fixture(other, member_fixture(other))

      assert [%Runner{id: id}] = Runners.list_runners(workspace)
      assert id == runner.id
      assert Runners.get_runner!(workspace, runner.id).id == runner.id
      assert_raise Ecto.NoResultsError, fn -> Runners.get_runner!(other, runner.id) end
    end

    test "records what the runner announces", %{runner: runner} do
      hello =
        hello_fixture(%{
          labels: ["docker", "linux"],
          capacity: 8,
          runner_version: "0.2.0",
          agent: %{"cli_version" => "2.1.317", "auth" => "login"}
        })

      {:ok, updated} = Runners.record_hello(runner, hello)

      assert %{labels: ["docker", "linux"], capacity: 8, runner_version: "0.2.0"} = updated
      assert updated.agent == %{"cli_version" => "2.1.317", "auth" => "login"}
      assert updated.last_connected_at

      :ok = Runners.touch_last_seen(updated)
      assert Repo.reload(updated).last_seen_at
    end

    test "a runner on a release older than the control plane's is outdated", %{runner: runner} do
      outdated? = fn version, reference ->
        Runners.outdated?(%{runner | runner_version: version}, reference)
      end

      assert outdated?.("2026-11-04.01", "2026-11-04.02")
      assert outdated?.("2026-11-04.01", "2026-11-04.02+dev.abc1234")
      refute outdated?.("2026-11-04.02", "2026-11-04.02")
      refute outdated?.("2026-11-05.01", "2026-11-04.02")
      refute outdated?.("2026-11-04.01+dev.abc1234", "2026-11-04.02")
      refute outdated?.("dev+abc1234", "2026-11-04.02")
      refute outdated?.("0.1.0", "2026-11-04.02")
      refute outdated?.(nil, "2026-11-04.02")
      refute outdated?.("2026-11-04.01", "dev+abc1234")
    end

    test "by default, compared with this control plane's version", %{runner: runner} do
      assert Runners.outdated?(%{runner | runner_version: "2026-11-04.01"})
      refute Runners.outdated?(%{runner | runner_version: "2026-11-04.02"})
    end

    test "records its worktrees' disk usage", %{runner: runner} do
      usage = %{"count" => 2, "bytes" => 2_048, "free_bytes" => nil}
      assert {:ok, %Runner{worktree_usage: ^usage}} = Runners.update_worktree_usage(runner, usage)
      assert {:error, _} = Runners.update_worktree_usage(runner, %{"count" => "x"})
    end

    test "renames", %{runner: runner} do
      assert {:ok, %Runner{name: "Novo nome"}} =
               Runners.rename_runner(runner, %{name: "Novo nome"})

      assert {:error, changeset} = Runners.rename_runner(runner, %{name: ""})
      assert errors_on(changeset).name != []
      assert %Ecto.Changeset{} = Runners.change_runner_name(runner)
    end

    test "revoking stops the token and hides the runner", %{
      workspace: workspace,
      runner: runner,
      token: token
    } do
      {:ok, revoked} = Runners.revoke_runner(runner)

      assert revoked.revoked_at
      refute Runners.authenticate_runner(token)
      assert Runners.list_runners(workspace) == []
    end
  end

  test "settings and formatting" do
    assert Runners.authorization_ttl_seconds() > Runners.poll_interval_seconds()
    assert Runners.format_user_code("WDJBMJHT") == "WDJB-MJHT"
  end
end
