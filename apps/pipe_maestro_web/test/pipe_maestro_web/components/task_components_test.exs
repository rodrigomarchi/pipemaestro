defmodule PipeMaestroWeb.TaskComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestroWeb.TaskComponents

  test "files show their lines, or what happened to them outside git, or that they are binary" do
    html =
      render_component(&TaskComponents.file_list/1,
        files: [
          %{"path" => "a.ex", "added" => 2, "removed" => 1},
          %{"path" => "logo.png", "added" => nil, "removed" => nil},
          %{"path" => "notas.md", "added" => nil, "removed" => nil, "status" => "new"},
          %{"path" => "velho.md", "added" => nil, "removed" => nil, "status" => "removed"},
          %{"path" => "mudou.md", "added" => nil, "removed" => nil, "status" => "modified"}
        ]
      )

    assert html =~ "+2"
    assert html =~ ~r/binário.*logo\.png/s
    assert html =~ ~r/novo.*notas\.md/s
    assert html =~ ~r/removido.*velho\.md/s
    assert html =~ ~r/alterado.*mudou\.md/s
  end
end
