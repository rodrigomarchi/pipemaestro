defmodule PipeMaestroWeb.LandingShotsTest do
  use ExUnit.Case, async: true

  alias PipeMaestroWeb.LandingShots

  @max_bytes 600 * 1024
  @forbidden ~r/e2e|fake|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}/i

  defp file(path), do: Application.app_dir(:pipe_maestro_web, Path.join("priv/static", path))

  # A PNG starts with an 8-byte signature followed by the IHDR chunk, whose data opens with
  # the width and the height as 32-bit big-endian integers.
  defp png_size(path) do
    <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _len::32, "IHDR", width::32, height::32, _::binary>> =
      File.read!(path)

    {width, height}
  end

  test "lists the screens the landing shows, each with its copy and dimensions" do
    shots = LandingShots.all()

    assert Enum.map(shots, & &1.name) == ~w(board task decision audit usage runners)

    for shot <- shots do
      for key <- [:title, :text, :alt], do: assert(is_binary(Map.fetch!(shot, key)))
      assert String.trim(shot.alt) != ""
      assert is_integer(shot.width) and shot.width > 0
      assert is_integer(shot.height) and shot.height > 0
    end
  end

  test "lists the walkthrough's steps in order, each with its copy and its screens" do
    steps = LandingShots.walkthrough()

    assert Enum.map(steps, &Enum.map(&1.shots, fn shot -> shot.name end)) == [
             ~w(setup-runner),
             ~w(setup-project),
             ~w(setup-pipelines),
             ~w(setup-gate),
             ~w(setup-pipeline setup-pipeline-menu),
             ~w(setup-pipeline-stage),
             ~w(first-task-new),
             ~w(first-task-running first-task-stage),
             ~w(first-task-gate),
             ~w(first-task-done)
           ]

    for step <- steps do
      assert String.trim(step.title) != "" and String.trim(step.text) != ""
      assert Enum.all?(step.code, &is_binary/1)
      # Two screens side by side say what each one shows.
      if length(step.shots) > 1, do: assert(Enum.all?(step.shots, &is_binary(&1[:caption])))
    end
  end

  test "a close-up has the size of the director's detail box, a screen the window's" do
    {:ok, gate} = LandingShots.fetch("first-task-gate")
    assert {gate.kind, gate.width, gate.height} == {:detail, 1920, 900}

    {:ok, board} = LandingShots.fetch("board")
    assert {board.kind, board.width, board.height} == {:screen, 2880, 1800}
  end

  test "lists the further screens the documentation shows, and fetches any by name" do
    assert Enum.map(LandingShots.docs(), & &1.name) ==
             ~w(pipeline integrations notifications quality)

    names = Enum.map(LandingShots.every(), & &1.name)
    assert names == Enum.uniq(names)

    for shot <- LandingShots.every() do
      assert {:ok, ^shot} = LandingShots.fetch(shot.name)
      assert String.trim(shot.alt) != ""
    end

    assert LandingShots.fetch("nothing") == :error
  end

  test "path/2 names the light and dark files without random suffixes" do
    assert LandingShots.path("board", :light) == "/images/landing/board.png"
    assert LandingShots.path("board", :dark) == "/images/landing/board-dark.png"
  end

  for theme <- [:light, :dark] do
    test "every #{theme} screenshot exists, matches its declared size and stays small" do
      for shot <- LandingShots.every() do
        path = LandingShots.path(shot.name, unquote(theme))
        refute path =~ @forbidden
        assert File.regular?(file(path)), "missing #{path}; run make landing.shots"

        assert png_size(file(path)) == {shot.width, shot.height},
               "#{path} was captured with a different frame than LandingShots declares"

        assert File.stat!(file(path)).size < @max_bytes, "#{path} is over 600 KB"
      end
    end
  end
end
