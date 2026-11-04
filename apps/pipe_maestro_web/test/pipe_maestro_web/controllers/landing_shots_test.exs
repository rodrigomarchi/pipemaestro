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

  test "path/2 names the light and dark files without random suffixes" do
    assert LandingShots.path("board", :light) == "/images/landing/board.png"
    assert LandingShots.path("board", :dark) == "/images/landing/board-dark.png"
  end

  for theme <- [:light, :dark] do
    test "every #{theme} screenshot exists, matches its declared size and stays small" do
      for shot <- LandingShots.all() do
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
