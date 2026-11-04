# Evaluated by config/test.exs and config/e2e.exs. In a git worktree (each task
# of the control plane runs in one) it returns a suffix taken from the
# worktree's name, which keeps the worktree's databases apart from the main
# checkout's and from other worktrees', so tasks can run at once on one
# machine. In the main checkout it returns "".
case File.read(Path.expand("../.git", __DIR__)) do
  {:ok, "gitdir: " <> git_dir} ->
    name = git_dir |> String.trim() |> Path.basename() |> String.downcase()
    "_" <> (name |> String.replace(~r/[^a-z0-9]/, "") |> String.slice(0, 8))

  _checkout ->
    ""
end
