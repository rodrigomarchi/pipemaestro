defmodule PipeMaestroWeb.PageControllerTest do
  use PipeMaestroWeb.ConnCase, async: true

  test "GET / renders the landing page", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "Da issue ao Pull Request"
    assert html =~ ~s(id="como-funciona")
    assert html =~ ~s(href="/login")
  end

  test "the landing page leads to the documentation and its everyday examples", %{conn: conn} do
    doc = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    for page <- PipeMaestroWeb.Docs.section!("exemplos").pages do
      assert [href] =
               doc
               |> LazyHTML.query(~s([data-testid="example-#{page.slug}"]))
               |> LazyHTML.attribute("href")

      assert href == "/docs/#{page.slug}"
    end

    for testid <- ~w(nav-docs nav-docs-compact cta-docs) do
      assert doc |> LazyHTML.query(~s([data-testid="#{testid}"])) |> Enum.count() == 1
    end
  end

  test "the landing page does not promise that the platform never merges", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    refute html =~ "nunca são feitos pela plataforma"
    assert html =~ "o merge só é automático"
  end

  test "the landing page explains the platform simply and in diagrams", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "Explicado como para uma criança"
    for step <- 1..6, do: assert(html =~ ~s(data-testid="kid-step-#{step}"))

    for diagram <- ~w(hero-journey diagram-pipeline diagram-architecture diagram-stage),
        do: assert(html =~ ~s(data-testid="#{diagram}"))
  end

  describe "the real screenshots on the landing page" do
    @tour ~w(board task decision audit usage runners)

    defp landing(conn), do: conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    defp landing_imgs(doc), do: LazyHTML.query(doc, ~s(img[src^="/images/landing/"]))

    defp static_file(src) do
      relative = src |> URI.parse() |> Map.fetch!(:path) |> String.trim_leading("/")
      Application.app_dir(:pipe_maestro_web, Path.join("priv/static", relative))
    end

    test "the hero shows the product and the tour has one block per screen", %{conn: conn} do
      doc = landing(conn)

      for testid <- ~w(hero-screenshot product-tour nav-product) do
        assert LazyHTML.query(doc, ~s([data-testid="#{testid}"])) |> Enum.count() == 1,
               "expected exactly one #{testid}"
      end

      for name <- @tour do
        block = LazyHTML.query(doc, ~s([data-testid="product-tour"] [data-testid="tour-#{name}"]))
        assert Enum.count(block) == 1, "expected tour-#{name} inside product-tour"
      end

      assert [href] =
               doc
               |> LazyHTML.query(~s([data-testid="nav-product"]))
               |> LazyHTML.attribute("href")

      assert href == "/#produto"
      assert doc |> LazyHTML.query(~s(#produto[data-testid="product-tour"])) |> Enum.count() == 1
    end

    test "the walkthrough shows each step in order, with its screens light and dark", %{
      conn: conn
    } do
      doc = landing(conn)
      steps = PipeMaestroWeb.LandingShots.walkthrough()

      assert doc |> LazyHTML.query(~s(#passo-a-passo[data-testid="walkthrough"])) |> Enum.count() ==
               1

      for {step, index} <- Enum.with_index(steps, 1) do
        block = LazyHTML.query(doc, ~s([data-testid="walkthrough-step-#{index}"]))
        assert LazyHTML.text(block) =~ step.title

        for shot <- step.shots, theme <- ["", "-dark"] do
          img = LazyHTML.query(block, ~s(img[src="/images/landing/#{shot.name}#{theme}.png"]))
          assert Enum.count(img) == 1, "step #{index} does not show #{shot.name}#{theme}.png"
        end
      end
    end

    test "the screenshots come from PipeMaestroWeb.LandingShots, one per tour block" do
      assert Enum.map(PipeMaestroWeb.LandingShots.all(), & &1.name) == @tour
    end

    test "every screenshot referenced by the page exists, light and dark", %{conn: conn} do
      srcs = conn |> landing() |> landing_imgs() |> LazyHTML.attribute("src")

      for name <- @tour, theme <- ["", "-dark"] do
        assert Enum.any?(srcs, &String.starts_with?(&1, "/images/landing/#{name}#{theme}")),
               "the page does not reference #{name}#{theme}.png"
      end

      for src <- srcs, do: assert(File.regular?(static_file(src)), "missing file for #{src}")
    end

    test "each screenshot pair follows the dark class of the page", %{conn: conn} do
      doc = landing(conn)

      for name <- @tour do
        block = LazyHTML.query(doc, ~s([data-testid="tour-#{name}"]))
        light = LazyHTML.query(block, ~s(img[src^="/images/landing/#{name}."]))
        dark = LazyHTML.query(block, ~s(img[src^="/images/landing/#{name}-dark."]))

        assert [light_class] = LazyHTML.attribute(light, "class")
        assert [dark_class] = LazyHTML.attribute(dark, "class")
        assert "dark:hidden" in String.split(light_class)
        assert "hidden" in String.split(dark_class)
        assert "dark:block" in String.split(dark_class)
      end
    end

    test "every screenshot has alt text and fixed dimensions; only the hero loads eagerly",
         %{conn: conn} do
      doc = landing(conn)

      hero_srcs =
        doc
        |> LazyHTML.query(~s([data-testid="hero-screenshot"] img))
        |> LazyHTML.attribute("src")

      assert hero_srcs != []

      for img <- doc |> landing_imgs() |> Enum.to_list() do
        [src] = LazyHTML.attribute(img, "src")
        assert [alt] = LazyHTML.attribute(img, "alt")
        assert String.trim(alt) != "", "#{src} has no alt text"
        assert [width] = LazyHTML.attribute(img, "width")
        assert [height] = LazyHTML.attribute(img, "height")
        assert String.to_integer(width) > 0 and String.to_integer(height) > 0

        expected = if src in hero_srcs, do: "eager", else: "lazy"
        assert LazyHTML.attribute(img, "loading") == [expected], "#{src} should load #{expected}"
      end
    end
  end
end

defmodule PipeMaestroWeb.HealthControllerTest do
  use PipeMaestroWeb.ConnCase, async: true

  test "GET /healthz answers ok", %{conn: conn} do
    assert conn |> get(~p"/healthz") |> text_response(200) == "ok"
  end

  test "GET /version answers the control plane's version and release", %{conn: conn} do
    assert %{"version" => version, "release" => release} =
             conn |> get(~p"/version") |> json_response(200)

    assert version == PipeMaestro.Version.version()
    assert release == to_string(Application.spec(:pipe_maestro, :vsn))
  end

  test "GET /version also answers the runner's version the control plane requires", %{
    conn: conn
  } do
    assert %{"runner_version" => runner_version} =
             conn |> get(~p"/version") |> json_response(200)

    assert runner_version == PipeMaestro.Version.runner_version()
  end
end
