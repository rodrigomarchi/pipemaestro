defmodule ClaudeControlPlaneWeb.ActivateRunnerLiveTest do
  use ClaudeControlPlaneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ClaudeControlPlane.Runners

  setup :register_and_log_in_member

  defp start_sign_in(name \\ nil) do
    {:ok, _auth, device_code, user_code} =
      Runners.start_device_authorization(hello_fixture(%{hostname: "build-box"}), name)

    %{device_code: device_code, user_code: user_code}
  end

  test "requires a signed-in user and comes back with the code" do
    conn = get(build_conn(), ~p"/runners/activate?code=ABCD-EFGH")

    assert redirected_to(conn) == ~p"/login"
    assert get_session(conn, :user_return_to) == "/runners/activate?code=ABCD-EFGH"
  end

  test "approves a runner from the code in the link", %{conn: conn, workspace: workspace} do
    %{device_code: device_code, user_code: user_code} = start_sign_in()
    {:ok, view, _html} = live(conn, ~p"/runners/activate?code=#{user_code}")

    assert view |> element("[data-testid=activate-hostname]") |> render() =~ "build-box"

    view
    |> form("#activate-approval-form",
      approval: %{workspace_id: workspace.id, name: "Servidor de build"}
    )
    |> render_submit()

    assert has_element?(view, "[data-testid=activate-approved]", "Servidor de build")
    assert {:ok, runner, _token} = Runners.exchange_device_code(device_code)
    assert runner.workspace_id == workspace.id
  end

  test "looks a typed code up, whatever its case", %{conn: conn} do
    %{user_code: user_code} = start_sign_in()
    {:ok, view, _html} = live(conn, ~p"/runners/activate")

    view
    |> form("#activate-code-form", lookup: %{code: String.downcase(user_code)})
    |> render_submit()

    assert has_element?(view, "[data-testid=activate-request]")
  end

  test "explains an unknown or expired code", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/runners/activate")

    assert view
           |> form("#activate-code-form", lookup: %{code: "ZZZZ-ZZZZ"})
           |> render_submit() =~ "Código inválido ou expirado"
  end

  test "denies a sign-in", %{conn: conn} do
    %{device_code: device_code, user_code: user_code} = start_sign_in()
    {:ok, view, _html} = live(conn, ~p"/runners/activate?code=#{user_code}")

    view |> element("[data-testid=activate-deny]") |> render_click()

    assert has_element?(view, "[data-testid=activate-denied]")
    assert Runners.exchange_device_code(device_code) == {:error, :access_denied}
  end

  test "keeps the form when the name is empty", %{conn: conn, workspace: workspace} do
    %{user_code: user_code} = start_sign_in()
    {:ok, view, _html} = live(conn, ~p"/runners/activate?code=#{user_code}")

    view
    |> form("#activate-approval-form", approval: %{workspace_id: workspace.id, name: ""})
    |> render_submit()

    assert has_element?(view, "#activate-approval-form")
  end

  test "refuses a workspace the user does not belong to", %{conn: conn} do
    %{user_code: user_code} = start_sign_in()
    other = workspace_fixture()
    {:ok, view, _html} = live(conn, ~p"/runners/activate?code=#{user_code}")

    assert render_submit(view, "approve", %{
             "approval" => %{"workspace_id" => other.id, "name" => "x"}
           }) =~ "não pode ser aprovado aqui"
  end

  test "a user without workspaces cannot approve" do
    conn = log_in_user(build_conn(), user_fixture())
    %{user_code: user_code} = start_sign_in()
    {:ok, view, _html} = live(conn, ~p"/runners/activate?code=#{user_code}")

    assert render(view) =~ "não é admin de nenhum workspace"
    refute has_element?(view, "#activate-approval-form")
  end
end
