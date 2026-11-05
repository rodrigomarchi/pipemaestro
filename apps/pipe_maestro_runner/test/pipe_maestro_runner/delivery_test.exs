defmodule PipeMaestroRunner.DeliveryTest do
  use ExUnit.Case, async: true

  alias PipeMaestroRunner.Delivery

  @fake_gh Path.expand("../support/fake_gh", __DIR__)

  @moduletag :tmp_dir

  defp git!(dir, args) do
    {out, 0} =
      System.cmd("git", ["-C", dir, "-c", "user.email=t@t", "-c", "user.name=t" | args],
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  setup %{tmp_dir: dir} do
    origin = Path.join(dir, "origin.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", origin])
    repo = Path.join(dir, "app")
    {_, 0} = System.cmd("git", ["clone", "-q", origin, repo], stderr_to_stdout: true)
    File.write!(Path.join(repo, "README.md"), "app")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "init"])
    git!(repo, ["push", "-q", "origin", "HEAD:main"])
    git!(repo, ["checkout", "-q", "-b", "cp/tarefa"])
    log = Path.join(dir, "gh.log")
    %{repo: repo, origin: origin, log: log, env: [{"FAKE_GH_LOG", log}]}
  end

  defp deliver(ctx, delivery, exclude \\ []),
    do: Delivery.deliver(ctx.repo, delivery, exclude, gh: @fake_gh, env: ctx.env)

  test "commits what changed, leaving out the copied paths", ctx do
    File.write!(Path.join(ctx.repo, "lib.ex"), "novo")
    File.mkdir_p!(Path.join(ctx.repo, "deps"))
    File.write!(Path.join(ctx.repo, "deps/x"), "copiado")

    report = deliver(ctx, %{"commit_message" => "Triagem: feito"}, ["deps"])
    assert report["commit"] =~ ~r/^[0-9a-f]{40}$/
    refute report["pushed"]
    assert git!(ctx.repo, ["log", "-1", "--format=%s"]) == "Triagem: feito"
    assert git!(ctx.repo, ["show", "--name-only", "--format=", "HEAD"]) == "lib.ex"

    # Nothing new: no empty commit.
    assert deliver(ctx, %{"commit_message" => "de novo"}, ["deps"])["commit"] == nil
  end

  test "commits when a copied path is one the .gitignore already ignores", ctx do
    File.write!(Path.join(ctx.repo, ".gitignore"), "/deps/\nnode_modules/\n")
    git!(ctx.repo, ["add", ".gitignore"])
    git!(ctx.repo, ["commit", "-q", "-m", "ignore"])
    File.mkdir_p!(Path.join(ctx.repo, "deps"))
    File.write!(Path.join(ctx.repo, "deps/x"), "copiado")
    File.mkdir_p!(Path.join(ctx.repo, "e2e/node_modules"))
    File.write!(Path.join(ctx.repo, "e2e/node_modules/y"), "copiado")
    File.mkdir_p!(Path.join(ctx.repo, "_build"))
    File.write!(Path.join(ctx.repo, "_build/z"), "copiado, não ignorado")
    File.write!(Path.join(ctx.repo, "lib.ex"), "novo")

    report =
      deliver(ctx, %{"commit_message" => "Plano: feito"}, ["deps", "e2e/node_modules", "_build"])

    refute report["error"]
    assert report["commit"] =~ ~r/^[0-9a-f]{40}$/
    assert git!(ctx.repo, ["show", "--name-only", "--format=", "HEAD"]) == "lib.ex"
  end

  test "pushes the branch, opens the draft PR, then updates it and marks it ready", ctx do
    File.write!(Path.join(ctx.repo, "a.ex"), "a")
    pr = %{"title" => "Corrigir login", "body" => "Closes #1", "ready" => false}

    report = deliver(ctx, %{"commit_message" => "a", "push" => true, "pr" => pr})
    assert report["pushed"]
    assert report["pr_url"] == "https://github.com/acme/app/pull/01"
    assert git!(ctx.origin, ["log", "-1", "--format=%s", "cp/tarefa"]) == "a"

    File.write!(Path.join(ctx.repo, "b.ex"), "b")

    report =
      deliver(ctx, %{"commit_message" => "b", "push" => true, "pr" => %{pr | "ready" => true}})

    assert report["pr_url"] == "https://github.com/acme/app/pull/01"

    calls = ctx.log |> File.read!() |> String.split("\n", trim: true)
    assert Enum.count(calls, &String.starts_with?(&1, "pr create --draft")) == 1
    assert Enum.any?(calls, &String.starts_with?(&1, "pr edit"))
    assert List.last(calls) =~ "pr ready"
  end

  test "comments on the issue", ctx do
    comment = %{"url" => "https://github.com/acme/app/issues/1", "body" => "Decisão: x"}
    report = deliver(ctx, %{"commit_message" => "nada", "issue_comment" => comment})
    assert report["commented"]

    assert File.read!(ctx.log) =~
             "issue comment https://github.com/acme/app/issues/1 --body Decisão: x"
  end

  test "a failure is reported, not raised", ctx do
    File.write!(Path.join(ctx.repo, "a.ex"), "a")
    pr = %{"title" => "Quebra [gh-falha]", "body" => "b", "ready" => false}

    report = deliver(ctx, %{"commit_message" => "a", "push" => true, "pr" => pr})
    assert report["commit"]
    assert report["pushed"]
    assert report["error"] =~ "falha simulada"
    refute report["pr_url"]
  end
end
