defmodule PipeMaestroRunner.ChecksTest do
  use ExUnit.Case, async: true

  alias PipeMaestroRunner.{Checks, RepoState}

  @moduletag :tmp_dir

  @isolated [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]

  defp git!(dir, args) do
    {out, 0} =
      System.cmd("git", ["-C", dir, "-c", "user.email=t@t", "-c", "user.name=t" | args],
        stderr_to_stdout: true,
        env: @isolated
      )

    String.trim(out)
  end

  defp commit!(dir, file, text) do
    File.mkdir_p!(Path.dirname(Path.join(dir, file)))
    File.write!(Path.join(dir, file), text)
    git!(dir, ["add", file])
    git!(dir, ["commit", "-q", "-m", file])
  end

  # A task's worktree (`app`, on cp/t, pushed) and another clone (`other`),
  # standing for a person or an agent elsewhere pushing to the same branch.
  setup %{tmp_dir: dir} do
    origin = Path.join(dir, "origin.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", origin])
    app = Path.join(dir, "app")
    {_, 0} = System.cmd("git", ["clone", "-q", origin, app], stderr_to_stdout: true)
    commit!(app, "README.md", "app")
    git!(app, ["push", "-q", "origin", "HEAD:main"])
    git!(app, ["remote", "set-head", "origin", "main"])
    git!(app, ["checkout", "-q", "-b", "cp/t"])
    commit!(app, "lib.ex", "trabalho")
    git!(app, ["push", "-q", "-u", "origin", "cp/t"])

    other = Path.join(dir, "other")

    {_, 0} =
      System.cmd("git", ["clone", "-q", "-b", "cp/t", origin, other], stderr_to_stdout: true)

    %{app: app, other: other}
  end

  defp run(dir, check, opts \\ []), do: dir |> Checks.run([check], opts) |> hd()

  defp passes?(dir, check, opts \\ []), do: run(dir, check, opts)["passed"]

  describe "checks" do
    test "each result has a gate's shape and says why it failed", %{app: app} do
      git!(app, ["checkout", "-q", "-b", "outra"])

      assert %{
               "platform" => true,
               "id" => "branch",
               "passed" => false,
               "expect" => "pass",
               "exit_code" => 1,
               "command" => "plataforma: " <> _,
               "message" => message
             } = run(app, %{"id" => "branch", "branch" => "cp/t"})

      assert message =~ "branch `outra`"
      assert message == run(app, %{"id" => "branch", "branch" => "cp/t"})["output"]
    end

    test "branch: HEAD on the task's branch, not detached", %{app: app} do
      assert passes?(app, %{"id" => "branch", "branch" => "cp/t"})
      git!(app, ["checkout", "-q", "--detach"])
      assert run(app, %{"id" => "branch", "branch" => "cp/t"})["message"] =~ "solto"
    end

    test "no_operation: a merge left with conflicts", %{app: app} do
      assert passes?(app, %{"id" => "no_operation"})
      git!(app, ["checkout", "-q", "-b", "lado"])
      commit!(app, "lib.ex", "lado")
      git!(app, ["checkout", "-q", "cp/t"])
      commit!(app, "lib.ex", "aqui")
      System.cmd("git", ["-C", app, "merge", "lado"], stderr_to_stdout: true, env: @isolated)

      message = run(app, %{"id" => "no_operation"})["message"]
      assert message =~ "um merge"
      assert message =~ "`lib.ex`"
    end

    test "contains_origin: a commit pushed by someone else is missing", %{app: app, other: other} do
      assert passes?(app, %{"id" => "contains_origin", "branch" => "cp/t"})
      commit!(other, "revisao.ex", "sugestão do revisor")
      git!(other, ["push", "-q", "origin", "cp/t"])

      assert run(app, %{"id" => "contains_origin", "branch" => "cp/t"})["message"] =~
               "não contém 1 commit"
    end

    test "clean: lists what was left, but not copied paths nor the artifacts", %{app: app} do
      File.mkdir_p!(Path.join(app, "deps/x"))
      File.write!(Path.join(app, "deps/x/a"), "copiado")
      File.mkdir_p!(Path.join(app, ".control-plane/t"))
      File.write!(Path.join(app, ".control-plane/t/01-plano.md"), "plano")
      check = %{"id" => "clean", "artifacts" => ".control-plane/t"}

      assert passes?(app, check, exclude: ["deps"])

      File.write!(Path.join(app, "esquecido.ex"), "x")
      File.write!(Path.join(app, "lib.ex"), "mudou")
      message = run(app, check, exclude: ["deps"])["message"]
      assert message =~ "`esquecido.ex`"
      assert message =~ "`lib.ex`"
      refute message =~ "deps"
    end

    test "artifact_committed and no_artifacts", %{app: app} do
      path = ".control-plane/t/01-plano.md"
      File.mkdir_p!(Path.join(app, ".control-plane/t"))
      File.write!(Path.join(app, path), "plano")
      refute passes?(app, %{"id" => "artifact_committed", "path" => path})

      git!(app, ["add", path])
      git!(app, ["commit", "-q", "-m", "plano"])
      assert passes?(app, %{"id" => "artifact_committed", "path" => path})

      assert run(app, %{"id" => "no_artifacts", "path" => ".control-plane/t"})["message"] =~
               "--cached"

      git!(app, ["rm", "-q", "-r", "--cached", ".control-plane/t"])
      git!(app, ["commit", "-q", "-m", "sem artefatos"])
      assert passes?(app, %{"id" => "no_artifacts", "path" => ".control-plane/t"})
      assert File.exists?(Path.join(app, path))
    end

    test "no_secrets: names the secret and the file, never the value", %{app: app} do
      env = [{"API_TOKEN", "tok-super-secreto-123"}, {"CURTO", "abc"}]
      assert passes?(app, %{"id" => "no_secrets"}, env: env)

      commit!(app, "config.exs", "token: tok-super-secreto-123")
      File.write!(Path.join(app, ".env"), "API_TOKEN=tok-super-secreto-123")
      %{"message" => message, "output" => output} = run(app, %{"id" => "no_secrets"}, env: env)

      assert message =~ "`API_TOKEN` em `config.exs`"
      assert message =~ "`API_TOKEN` em `.env`"
      refute message =~ "tok-super-secreto"
      refute output =~ "tok-super-secreto"
    end
  end

  describe "sync before a stage" do
    test "nothing to tell on a worktree in step with origin", %{app: app} do
      assert RepoState.sync(app, "cp/t") == nil
    end

    test "fast-forwards to what someone else pushed, and says so", %{app: app, other: other} do
      commit!(other, "revisao.ex", "sugestão")
      git!(other, ["push", "-q", "origin", "cp/t"])

      assert RepoState.sync(app, "cp/t") =~ "atualizado por fast-forward"
      assert File.read!(Path.join(app, "revisao.ex")) == "sugestão"
    end

    test "a divergence is told, not resolved", %{app: app, other: other} do
      commit!(other, "revisao.ex", "sugestão")
      git!(other, ["push", "-q", "origin", "cp/t"])
      commit!(app, "local.ex", "local")

      report = RepoState.sync(app, "cp/t")
      assert report =~ "1 commit(s) na branch `cp/t` que o worktree não tem"
      assert report =~ "o worktree tem 1"
      refute File.exists?(Path.join(app, "revisao.ex"))
    end

    test "a dirty worktree is not fast-forwarded", %{app: app, other: other} do
      commit!(other, "revisao.ex", "sugestão")
      git!(other, ["push", "-q", "origin", "cp/t"])
      File.write!(Path.join(app, "lib.ex"), "em andamento")

      assert RepoState.sync(app, "cp/t") =~ "que o worktree não tem"
      assert File.read!(Path.join(app, "lib.ex")) == "em andamento"
    end

    test "another branch and a lock are told", %{app: app} do
      git!(app, ["checkout", "-q", "-b", "outra"])
      File.write!(Path.join(app, ".git/index.lock"), "")

      report = RepoState.sync(app, "cp/t")
      assert report =~ "na branch `outra`"
      assert report =~ "index.lock"
    end
  end
end
