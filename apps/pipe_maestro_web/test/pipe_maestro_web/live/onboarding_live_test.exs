defmodule PipeMaestroWeb.OnboardingLiveTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.Workspaces

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, workspace} = Workspaces.create_owned_workspace(user, %{"name" => "Acme"})
    %{conn: log_in_user(conn, user), user: user, workspace: workspace}
  end

  test "the board of a new Free beta workspace opens the lesson", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/w/acme/onboarding"}}} = live(conn, ~p"/w/acme")
  end

  test "the first step shows how to connect the runner", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/w/acme/onboarding")
    [runner | _] = PipeMaestroWeb.LandingShots.walkthrough()

    assert has_element?(view, ~s([data-testid="onboarding-step-1"]))
    assert html =~ "Conecte o runner"
    for line <- runner.code, do: assert(html =~ line)
    assert html =~ "/images/landing/setup-runner.png"
    assert has_element?(view, ~s(a[href="/docs/primeiros-passos"]))
    refute has_element?(view, ~s([data-testid="onboarding-back"]))
  end

  test "goes through the three steps and back", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/w/acme/onboarding")

    view |> element(~s([data-testid="onboarding-next"])) |> render_click()
    assert_patch(view, ~p"/w/acme/onboarding?step=2")
    assert render(view) =~ "Cadastre o projeto"

    view |> element(~s([data-testid="onboarding-next"])) |> render_click()
    assert_patch(view, ~p"/w/acme/onboarding?step=3")
    assert render(view) =~ "Escolha um pipeline"
    refute has_element?(view, ~s([data-testid="onboarding-next"]))
    assert has_element?(view, ~s([data-testid="onboarding-start-runner"]))
    assert has_element?(view, ~s([data-testid="onboarding-finish"]))

    view |> element(~s([data-testid="onboarding-back"])) |> render_click()
    assert_patch(view, ~p"/w/acme/onboarding?step=2")
  end

  test "an unknown step shows the first", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/w/acme/onboarding?step=9")
    assert has_element?(view, ~s([data-testid="onboarding-step-1"]))
  end

  test "skipping ends the lesson for good", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/w/acme/onboarding")

    view |> element(~s([data-testid="onboarding-skip"])) |> render_click()
    assert_redirect(view, ~p"/w/acme")

    assert {:ok, _view, _html} = live(conn, ~p"/w/acme")
  end

  test "finishing goes to the board", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/w/acme/onboarding?step=3")

    view |> element(~s([data-testid="onboarding-finish"])) |> render_click()
    assert_redirect(view, ~p"/w/acme")
    assert {:ok, _view, _html} = live(conn, ~p"/w/acme")
  end

  test "starting from the runner goes to the runners and ends the lesson", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/w/acme/onboarding?step=3")

    view |> element(~s([data-testid="onboarding-start-runner"])) |> render_click()
    assert_redirect(view, ~p"/w/acme/runners")
    assert {:ok, _view, _html} = live(conn, ~p"/w/acme")
  end

  test "a member who is not an admin goes straight to the board", %{
    conn: conn,
    workspace: workspace
  } do
    member = member_fixture(workspace)
    conn = log_in_user(conn, member)

    assert {:ok, _view, _html} = live(conn, ~p"/w/acme")
  end

  test "the lesson is only for whom it is pending", %{conn: conn, workspace: workspace} do
    member = member_fixture(workspace)

    assert {:error, {:live_redirect, %{to: "/w/acme"}}} =
             conn |> log_in_user(member) |> live(~p"/w/acme/onboarding")

    {:ok, view, _html} = live(conn, ~p"/w/acme/onboarding")
    view |> element(~s([data-testid="onboarding-skip"])) |> render_click()

    assert {:error, {:live_redirect, %{to: "/w/acme"}}} = live(conn, ~p"/w/acme/onboarding")
  end

  test "welcomes without assuming anyone's gender", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/w/acme/onboarding")
    assert html =~ "Boas-vindas ao Acme"
  end

  test "a workspace an operator created never shows the lesson", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Globex", slug: "globex"})
    admin = member_fixture(workspace)

    assert {:ok, _view, _html} = conn |> log_in_user(admin) |> live(~p"/w/globex")
  end
end
