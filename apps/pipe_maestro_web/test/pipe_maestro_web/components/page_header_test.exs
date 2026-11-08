defmodule PipeMaestroWeb.PageHeaderTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PipeMaestroWeb.PageHeader

  defp action(attrs), do: Map.merge(%{__slot__: :action, inner_block: nil}, Map.new(attrs))

  defp actions(entries), do: render_component(&PageHeader.page_actions/1, action: entries)

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp count(html, selector), do: html |> query(selector) |> Enum.count()

  defp attribute(html, selector, name),
    do: html |> query(selector) |> LazyHTML.attribute(name) |> List.first()

  describe "page_actions/1" do
    test "renders nothing without actions" do
      assert actions([]) |> String.trim() == ""
    end

    test "one action is a button of its own, with no menu" do
      html =
        actions([
          action(
            label: "Nova tarefa",
            icon: "hero-plus",
            on_click: "open_new",
            primary: true,
            testid: "new-task"
          )
        ])

      assert count(html, "[data-testid=new-task]") == 1
      assert count(html, "[data-testid=page-actions-trigger]") == 0
      assert attribute(html, "[data-testid=new-task]", "aria-label") == "Nova tarefa"
      assert attribute(html, "[data-testid=new-task]", "class") =~ "pc-button--primary"
    end

    test "one link action keeps its path" do
      html =
        actions([
          action(label: "Editar", icon: "hero-pencil", navigate: "/x/edit", testid: "edit")
        ])

      assert attribute(html, "[data-testid=edit]", "href") == "/x/edit"
    end

    test "two or more actions fold into the menu, dangerous ones last" do
      html =
        actions([
          action(
            label: "Cancelar",
            icon: "hero-stop",
            on_click: "cancel",
            confirm: "Cancelar?",
            danger: true,
            testid: "cancel"
          ),
          action(
            label: "Duplicar",
            icon: "hero-document-duplicate",
            navigate: "/dup",
            testid: "dup"
          ),
          action(label: "Reexecutar", icon: "hero-arrow-path", on_click: "rerun", testid: "rerun")
        ])

      assert count(html, "[data-testid=page-actions-trigger]") == 1
      assert count(html, "#page-actions-menu [role=menuitem]") == 3
      assert count(html, "#page-actions-menu [role=separator]") == 1

      ids =
        html |> query("#page-actions-menu [role=menuitem]") |> LazyHTML.attribute("data-testid")

      assert ids == ["dup", "rerun", "cancel"]

      assert attribute(html, "[data-testid=dup]", "href") == "/dup"
      assert attribute(html, "[data-testid=cancel]", "data-confirm") == "Cancelar?"
      assert attribute(html, "[data-testid=rerun]", "phx-click") =~ "rerun"
    end
  end
end
