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

  defp deliver(ctx, delivery),
    do: Delivery.deliver(ctx.repo, delivery, gh: @fake_gh, env: ctx.env)

  # The agent's own commit, as the stage leaves it.
  defp commit!(ctx, file, message) do
    File.write!(Path.join(ctx.repo, file), message)
    git!(ctx.repo, ["add", file])
    git!(ctx.repo, ["commit", "-q", "-m", message])
  end

  test "never commits: delivers the commits the agent made", ctx do
    commit!(ctx, "lib.ex", "Implementação")
    File.write!(Path.join(ctx.repo, "solto.txt"), "não é do harness commitar")

    report = deliver(ctx, %{"push" => true})
    refute report["error"]
    assert report["commit"] == git!(ctx.repo, ["rev-parse", "HEAD"])
    assert git!(ctx.origin, ["log", "-1", "--format=%s", "cp/tarefa"]) == "Implementação"
    assert git!(ctx.repo, ["status", "--porcelain"]) == "?? solto.txt"
  end

  test "a branch the agent already pushed is pushed again as a no-op", ctx do
    commit!(ctx, "a.ex", "a")
    git!(ctx.repo, ["push", "-q", "origin", "HEAD"])

    report = deliver(ctx, %{"push" => true})
    assert report["pushed"]
    refute report["error"]
  end

  test "opens the draft PR with its block, keeps what others wrote, then marks it ready", ctx do
    commit!(ctx, "a.ex", "a")
    pr = %{"title" => "Corrigir login", "block" => "- [ ] Plano", "ready" => false}

    report = deliver(ctx, %{"push" => true, "pr" => pr})
    assert report["pushed"]
    assert report["pr_url"] == "https://github.com/acme/app/pull/01"
    body_file = ctx.log <> ".body.01"

    assert File.read!(body_file) =~
             "<!-- pipemaestro:inicio -->\n- [ ] Plano\n<!-- pipemaestro:fim -->"

    # A reviewer writes in the description, around the platform's block.
    File.write!(body_file, "Nota da revisão.\n\n" <> File.read!(body_file) <> "\n\nP.S.")

    commit!(ctx, "b.ex", "b")
    ready = %{pr | "block" => "- [x] Plano", "ready" => true}
    assert deliver(ctx, %{"push" => true, "pr" => ready})["pr_url"] =~ "/pull/01"

    body = File.read!(body_file)
    assert body =~ "Nota da revisão."
    assert body =~ "- [x] Plano"
    refute body =~ "- [ ] Plano"
    assert body =~ "P.S."

    calls = ctx.log |> File.read!() |> String.split("\n", trim: true)
    assert Enum.count(calls, &String.starts_with?(&1, "pr create --draft")) == 1
    assert List.last(calls) =~ "pr ready"
  end

  test "comments on the issue", ctx do
    comment = %{"url" => "https://github.com/acme/app/issues/1", "body" => "Decisão: x"}
    report = deliver(ctx, %{"issue_comment" => comment})
    assert report["commented"]

    assert File.read!(ctx.log) =~
             "issue comment https://github.com/acme/app/issues/1 --body Decisão: x"
  end

  test "a failure is reported, not raised", ctx do
    commit!(ctx, "a.ex", "a")
    pr = %{"title" => "Quebra [gh-falha]", "block" => "b", "ready" => false}

    report = deliver(ctx, %{"push" => true, "pr" => pr})
    assert report["pushed"]
    assert report["error"] =~ "falha simulada"
    refute report["pr_url"]
  end
end
