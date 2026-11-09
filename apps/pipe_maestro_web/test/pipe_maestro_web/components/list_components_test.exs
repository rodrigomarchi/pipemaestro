defmodule PipeMaestroWeb.ListComponentsTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias PipeMaestroWeb.ListComponents

  defp card(assigns) do
    ~H"""
    <ListComponents.record_list testid="things" empty={@empty}>
      <ListComponents.record_card
        testid="thing-1"
        navigate={@navigate}
        link_testid="thing-link-1"
        tone={@tone}
      >
        <:leading><span data-testid="thing-icon">i</span></:leading>
        <:title>Corrigir o login</:title>
        <:badge><span data-testid="thing-status">Executando</span></:badge>
        <:meta>Correção de bug · App</:meta>
        <:meta interactive><a href="/fora" data-testid="thing-outside">fora</a></:meta>
        <:body>Resumo do que foi feito.</:body>
        <:aside>
          <ListComponents.record_metric label="Custo" testid="thing-cost">
            US$ 0.42
          </ListComponents.record_metric>
        </:aside>
        <:actions :if={@actions}>
          <button data-testid="thing-remove">Remover</button>
        </:actions>
      </ListComponents.record_card>
      <:empty_state>
        <ListComponents.record_empty title="Nada aqui" testid="no-things" />
      </:empty_state>
    </ListComponents.record_list>
    """
  end

  defp render_card(overrides \\ %{}) do
    assigns =
      Map.merge(%{empty: false, navigate: "/coisas/1", tone: nil, actions: false}, overrides)

    rendered_to_string(card(assigns))
  end

  test "a record is a card in a list, with every place filled" do
    html = render_card()

    assert html =~ ~s(data-testid="things")
    assert html =~ ~s(role="list")
    assert html =~ ~s(data-testid="thing-1")
    assert html =~ ~s(data-testid="thing-icon")
    assert html =~ "Corrigir o login"
    assert html =~ ~s(data-testid="thing-status")
    assert html =~ "Correção de bug · App"
    assert html =~ "Resumo do que foi feito."
    assert html =~ ~s(data-testid="thing-cost")
    assert html =~ "Custo"
    # Its metrics go to the right once the card is wide.
    assert html =~ "@container"
    assert html =~ "@2xl:flex-col"
  end

  test "a card with a link is clickable as a whole; what is interactive sits above it" do
    html = render_card()

    assert html =~ ~r/<a[^>]*href="\/coisas\/1"[^>]*data-testid="thing-link-1"/
    assert html =~ "after:absolute after:inset-0"
    assert html =~ ~r/relative z-10">\s*<a[^>]*href="\/fora"/
    assert html =~ "hero-chevron-right"

    html = render_card(%{navigate: nil})
    refute html =~ "after:absolute"
    refute html =~ "hero-chevron-right"
  end

  test "actions sit in a row of their own, above the card's link" do
    html = render_card(%{actions: true})
    assert html =~ ~r/relative z-10 mt-3[^>]*>\s*<button[^>]*data-testid="thing-remove"/
    # The chevron gives way to the actions.
    refute html =~ "hero-chevron-right"
  end

  test "a card that sends an event is a button stretched over it, with its attributes" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <ListComponents.record_card
        click="open"
        click_value="n1"
        link_testid="item-n1"
        link_attrs={%{"data-unread" => "true"}}
      >
        <:title>Pronta</:title>
      </ListComponents.record_card>
      """)

    assert html =~ ~r/<button[^>]*phx-click="open"[^>]*phx-value-id="n1"/
    assert html =~ ~r/<button[^>]*data-testid="item-n1"[^>]*data-unread="true"/
    assert html =~ "after:absolute after:inset-0"
    assert html =~ "hero-chevron-right"
  end

  test "facts and metrics carry their icons; the icon tile has a dense size" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <ListComponents.record_fact icon="hero-folder" title="Projeto" testid="fact" mono>
        app
      </ListComponents.record_fact>
      <ListComponents.record_metric icon="hero-banknotes" title="Custo" testid="metric">
        US$ 1
      </ListComponents.record_metric>
      <ListComponents.record_icon icon="hero-play" color="info" small />
      """)

    assert html =~ "hero-folder"
    assert html =~ ~r/title="Projeto"/
    assert html =~ ~r/class="truncate font-mono"[^>]*data-testid="fact"/
    assert html =~ "hero-banknotes"
    assert html =~ ~r/title="Custo"/
    assert html =~ "hero-play"
    assert html =~ "size-8"
    assert html =~ "bg-info-50"
  end

  test "a tone calls attention" do
    assert render_card(%{tone: :awaiting}) =~ "border-warning-400"
    assert render_card(%{tone: :running}) =~ "border-info-400"
    assert render_card() =~ "border-gray-200"
  end

  test "without records, the listing says so instead" do
    html = render_card(%{empty: true})
    assert html =~ ~s(data-testid="no-things")
    assert html =~ "Nada aqui"
    refute html =~ ~s(data-testid="things")
  end

  test "the next page shows only while there is more" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <ListComponents.load_more more testid="things-load-more" />
      """)

    assert html =~ ~s(phx-click="load_more")
    assert html =~ "Carregar mais"

    html =
      rendered_to_string(~H"""
      <ListComponents.load_more more={false} testid="things-load-more" />
      """)

    refute html =~ "Carregar mais"
  end
end
