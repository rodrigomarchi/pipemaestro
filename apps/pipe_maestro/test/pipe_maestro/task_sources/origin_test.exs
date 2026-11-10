defmodule PipeMaestro.TaskSources.OriginTest do
  use ExUnit.Case, async: true

  alias PipeMaestro.TaskSources.Origin

  @url "https://github.com/acme/app/issues/42"

  defp origin(attrs), do: struct!(Origin, attrs)

  test "goes into a proposal's input and comes back the same" do
    origin =
      origin(
        source: "fake",
        external_id: "FAKE-1",
        url: "https://tracker.example.com/browse/FAKE-1",
        ref: %{"board" => "OPS"},
        linked_repo_id: nil
      )

    input = Origin.to_input(origin)
    assert %{"source" => "fake", "external_id" => "FAKE-1"} = input
    assert input |> JSON.encode!() |> JSON.decode!() == input
    assert Origin.from_input(%{"origin" => input, "project_id" => "x"}) == origin
  end

  test "reads a triage of a linked issue saved before the sources" do
    repo_id = Ecto.UUID.generate()

    origin =
      Origin.from_input(%{
        "issue_url" => @url,
        "linked_repo_id" => repo_id,
        "issue_number" => 42
      })

    assert origin.__struct__ == Origin

    assert %{
             source: "git_issue",
             external_id: @url,
             url: @url,
             ref: %{"number" => 42},
             linked_repo_id: ^repo_id
           } = origin
  end

  test "reads a proposal saved before the sources with only the issue's link" do
    assert %{source: "git_issue", external_id: @url, url: @url, ref: %{}, linked_repo_id: nil} =
             Origin.from_input(%{"issue_url" => @url})
  end

  test "an input without an origin has none" do
    assert Origin.from_input(%{"request" => "uma ideia"}) == nil
    assert Origin.from_input(nil) == nil
  end
end
