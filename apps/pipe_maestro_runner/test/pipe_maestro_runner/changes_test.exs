defmodule PipeMaestroRunner.ChangesTest do
  use ExUnit.Case, async: true

  alias PipeMaestroRunner.Changes

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    repo = Path.join(dir, "app")
    File.mkdir_p!(Path.join(repo, "lib"))
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    File.write!(Path.join(repo, "lib/a.ex"), "um\ndois\n")
    File.write!(Path.join(repo, ".gitignore"), "_build/\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "."])
    commit = ~w(-c user.email=t@t -c user.name=t commit -q -m init)
    {_, 0} = System.cmd("git", ["-C", repo | commit])
    %{repo: repo}
  end

  test "a snapshot sees edits, new files and removals, without touching the index", %{repo: repo} do
    {:ok, before} = Changes.snapshot(repo, [])

    File.write!(Path.join(repo, "lib/a.ex"), "um\ndois e meio\ntres\n")
    File.write!(Path.join(repo, "lib/b.ex"), "novo\n")
    File.mkdir_p!(Path.join(repo, "_build"))
    File.write!(Path.join(repo, "_build/x"), "ignorado")
    File.mkdir_p!(Path.join(repo, "deps"))
    File.write!(Path.join(repo, "deps/y"), "copiado")

    {:ok, later} = Changes.snapshot(repo, ["deps"])
    diff = Changes.diff(repo, before, later)

    assert diff["files"] == [
             %{"path" => "lib/a.ex", "added" => 2, "removed" => 1},
             %{"path" => "lib/b.ex", "added" => 1, "removed" => 0}
           ]

    assert diff["patch"] =~ "+dois e meio"
    assert diff["patch"] =~ "+++ b/lib/b.ex"
    assert diff["truncated"] == false

    # The real index is untouched: nothing is staged.
    {staged, 0} = System.cmd("git", ["-C", repo, "diff", "--cached", "--name-only"])
    assert staged == ""
  end

  test "commits made by the agent do not hide its changes", %{repo: repo} do
    {:ok, before} = Changes.snapshot(repo, [])
    File.write!(Path.join(repo, "lib/a.ex"), "trocado\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "."])
    commit = ~w(-c user.email=t@t -c user.name=t commit -q -m agente)
    {_, 0} = System.cmd("git", ["-C", repo | commit])

    {:ok, later} = Changes.snapshot(repo, [])
    assert [%{"path" => "lib/a.ex"}] = Changes.diff(repo, before, later)["files"]
  end

  test "a long patch is cut", %{repo: repo} do
    {:ok, before} = Changes.snapshot(repo, [])
    File.write!(Path.join(repo, "grande.txt"), String.duplicate("linha comprida\n", 20_000))
    {:ok, later} = Changes.snapshot(repo, [])

    diff = Changes.diff(repo, before, later, patch_bytes: 1_000)
    assert diff["truncated"] == true
    assert byte_size(diff["patch"]) <= 1_000
    assert [%{"path" => "grande.txt", "added" => 20_000}] = diff["files"]
  end

  test "binary files count without lines", %{repo: repo} do
    {:ok, before} = Changes.snapshot(repo, [])
    File.write!(Path.join(repo, "logo.png"), <<0, 1, 2, 255, 0>>)
    {:ok, later} = Changes.snapshot(repo, [])

    assert [%{"path" => "logo.png", "added" => nil, "removed" => nil}] =
             Changes.diff(repo, before, later)["files"]
  end

  test "outside a repository there is no snapshot", %{tmp_dir: dir} do
    plain = Path.join(dir, "solto")
    File.mkdir_p!(plain)
    assert {:error, _} = Changes.snapshot(plain, [])
  end

  describe "a directory without git" do
    test "lists the files created, modified and removed", %{tmp_dir: dir} do
      plain = Path.join(dir, "notas")
      File.mkdir_p!(Path.join(plain, "node_modules"))
      File.write!(Path.join(plain, "a.md"), "a")
      File.write!(Path.join(plain, "b.md"), "b")

      before = Changes.file_snapshot(plain)
      File.write!(Path.join(plain, "a.md"), "a mudou")
      File.rm!(Path.join(plain, "b.md"))
      File.write!(Path.join(plain, "c.md"), "c")
      File.write!(Path.join([plain, "node_modules", "x.js"]), "ignorado")

      assert Changes.file_report(plain, before) == %{
               "files" => [
                 %{"path" => "a.md", "added" => nil, "removed" => nil, "status" => "modified"},
                 %{"path" => "b.md", "added" => nil, "removed" => nil, "status" => "removed"},
                 %{"path" => "c.md", "added" => nil, "removed" => nil, "status" => "new"}
               ],
               "patch" => "",
               "truncated" => false,
               "task_files" => []
             }
    end
  end
end
