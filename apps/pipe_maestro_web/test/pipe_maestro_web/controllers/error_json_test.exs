defmodule PipeMaestroWeb.ErrorJSONTest do
  use PipeMaestroWeb.ConnCase, async: true

  test "renders 404" do
    assert PipeMaestroWeb.ErrorJSON.render("404.json", %{}) == %{
             errors: %{detail: "Not Found"}
           }
  end

  test "renders 500" do
    assert PipeMaestroWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
