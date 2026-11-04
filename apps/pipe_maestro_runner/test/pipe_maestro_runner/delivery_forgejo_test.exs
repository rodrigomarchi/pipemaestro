defmodule PipeMaestroRunner.DeliveryForgejoTest do
  use ExUnit.Case, async: true

  alias PipeMaestroRunner.Delivery
  alias PipeMaestroRunner.Delivery.Forgejo
  alias PipeMaestroRunner.Test.ForgejoServer

  @moduletag :tmp_dir

  # The machine's own git configuration (a keychain helper, say) stays out.
  @isolated [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]

  defp git!(dir, args) do
    {out, 0} =
      System.cmd("git", ["-C", dir, "-c", "user.email=t@t", "-c", "user.name=t" | args],
        stderr_to_stdout: true,
        env: @isolated
      )

    String.trim(out)
  end

  # A clone whose origin is https://forge.test/acme/app.git, pushed to a local
  # bare repository (insteadOf), with the API served on 127.0.0.1.
  setup %{tmp_dir: dir} do
    origin = Path.join(dir, "origin.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", origin])
    repo = Path.join(dir, "app")
    {_, 0} = System.cmd("git", ["clone", "-q", origin, repo], stderr_to_stdout: true)
    File.write!(Path.join(repo, "README.md"), "app")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "init"])
    git!(repo, ["push", "-q", "origin", "HEAD:main"])
    git!(repo, ["checkout", "-q", "-b", "cp/tarefa-1"])
    git!(repo, ["remote", "set-url", "origin", "https://forge.test/acme/app.git"])
    git!(repo, ["config", "url.#{origin}.insteadOf", "https://forge.test/acme/app.git"])

    server = ForgejoServer.start()
    %{repo: repo, origin: origin, server: server}
  end

  defp with_credential(ctx) do
    git!(ctx.repo, [
      "config",
      "credential.helper",
      "!f() { echo username=ana; echo password=segredo; }; f"
    ])

    ctx
  end

  defp deliver(ctx, delivery, env \\ []) do
    Delivery.deliver(ctx.repo, delivery, [],
      gh: nil,
      env: @isolated ++ env,
      forgejo_api_base: ctx.server.url
    )
  end

  defp stage(name, ready),
    do: %{
      "commit_message" => name,
      "push" => true,
      "pr" => %{"title" => "Corrigir login", "body" => "Etapa: #{name}", "ready" => ready}
    }

  test "opens a draft pull request on the first stage and marks it ready on the last", ctx do
    with_credential(ctx)
    File.write!(Path.join(ctx.repo, "plano.md"), "plano")

    report = deliver(ctx, stage("Plano", false))
    assert report["pushed"]
    assert report["pr_url"] == "https://forge.test/acme/app/pulls/1"
    refute report["error"]
    assert git!(ctx.origin, ["log", "-1", "--format=%s", "cp/tarefa-1"]) == "Plano"

    assert [%{title: "WIP: Corrigir login", head: "cp/tarefa-1", base: "main"}] =
             ForgejoServer.pulls(ctx.server)

    File.write!(Path.join(ctx.repo, "lib.ex"), "codigo")
    report = deliver(ctx, stage("Implementação", false))
    assert report["pr_url"] == "https://forge.test/acme/app/pulls/1"
    assert [%{body: "Etapa: Implementação"}] = ForgejoServer.pulls(ctx.server)

    File.write!(Path.join(ctx.repo, "docs.md"), "docs")
    report = deliver(ctx, stage("Entrega", true))
    assert report["pr_url"] == "https://forge.test/acme/app/pulls/1"
    assert [%{title: "Corrigir login", state: "open"}] = ForgejoServer.pulls(ctx.server)

    # Signed in as git push is: the credential helper's user and password.
    basic = "Basic " <> Base.encode64("ana:segredo")

    assert ctx.server
           |> ForgejoServer.requests()
           |> Enum.filter(fn {_method, path, _auth} -> path =~ "/repos/" end)
           |> Enum.all?(fn {_method, _path, auth} -> auth == basic end)
  end

  test "without a git credential, the FORGEJO_TOKEN secret signs in", ctx do
    File.write!(Path.join(ctx.repo, "a.ex"), "a")
    report = deliver(ctx, stage("Plano", false), [{"FORGEJO_TOKEN", "tok123"}])
    assert report["pr_url"]

    assert {"POST", _path, "token tok123"} =
             ctx.server
             |> ForgejoServer.requests()
             |> Enum.find(fn {method, _path, _auth} -> method == "POST" end)
  end

  test "comments on a Forgejo issue", ctx do
    with_credential(ctx)
    url = "https://forge.test/acme/app/issues/7"

    report =
      deliver(ctx, %{
        "commit_message" => "nada",
        "issue_comment" => %{"url" => url, "body" => "Decisão: x"}
      })

    assert report["commented"]
    assert ForgejoServer.comments(ctx.server) == [{"7", "Decisão: x"}]
  end

  test "an API failure is reported, not raised", ctx do
    with_credential(ctx)
    git!(ctx.repo, ["remote", "set-url", "origin", "https://forge.test/acme/outro.git"])
    git!(ctx.repo, ["config", "url.#{ctx.origin}.insteadOf", "https://forge.test/acme/outro.git"])
    File.write!(Path.join(ctx.repo, "a.ex"), "a")

    report = deliver(ctx, stage("Plano", false))
    assert report["pushed"]
    assert report["error"] =~ "pr: HTTP 404"
    refute report["pr_url"]
  end

  describe "repo/2 and parse/1" do
    test "reads the host and owner/name of https, scp-like and ssh remotes" do
      assert Forgejo.parse("https://git.example.com/acme/app.git") ==
               {:ok, "git.example.com", "acme/app"}

      assert Forgejo.parse("git@git.example.com:acme/app.git") ==
               {:ok, "git.example.com", "acme/app"}

      assert Forgejo.parse("ssh://git@Git.Example.com:2222/acme/app") ==
               {:ok, "git.example.com", "acme/app"}

      assert Forgejo.parse("/tmp/origin.git") == :error
    end

    test "GitHub, a local path, a host that is not a Forgejo and no sign-in are not Forgejo",
         ctx do
      auth = fn "forge.test" -> {:token, "tok"} end

      assert Forgejo.repo("https://github.com/acme/app.git", api_base: ctx.server.url, auth: auth) ==
               :not_forgejo

      assert Forgejo.repo("/tmp/origin.git") == :not_forgejo

      assert Forgejo.repo("https://forge.test/acme/app.git",
               api_base: "http://127.0.0.1:1",
               auth: auth
             ) ==
               :not_forgejo

      # A private instance answers the version to nobody else.
      assert Forgejo.repo("https://forge.test/acme/app.git", api_base: ctx.server.url) ==
               :not_forgejo

      assert {:ok, %{api: api, auth: {:token, "tok"}}} =
               Forgejo.repo("https://forge.test/acme/app.git",
                 api_base: ctx.server.url,
                 auth: auth
               )

      assert api == ctx.server.url <> "/api/v1/repos/acme/app"
    end
  end
end
