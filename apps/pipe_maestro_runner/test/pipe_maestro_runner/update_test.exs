defmodule PipeMaestroRunner.UpdateTest do
  use ExUnit.Case, async: true

  alias PipeMaestroProtocol.Downloads
  alias PipeMaestroRunner.{SelfUpdate, Update}
  alias PipeMaestroRunner.Test.DownloadServer

  @moduletag :tmp_dir

  @old "#!/bin/sh\necho vVELHO\n"
  @new "#!/bin/sh\necho vNOVO\n"
  @argv ["start", "--root", "/x"]

  setup %{tmp_dir: tmp} do
    {:ok, target} = SelfUpdate.target()

    served = Path.join(tmp, "served")
    File.mkdir_p!(served)
    DownloadServer.publish(served, Downloads.binary_name(target), @new)
    server = DownloadServer.start(served)

    bin_dir = Path.join(tmp, "bin")
    File.mkdir_p!(bin_dir)
    bin = Path.join(bin_dir, "pipemaestro")
    File.write!(bin, @old)
    File.chmod!(bin, 0o755)

    refusal = %{
      "reason" => "outdated",
      "version" => "dev+def5678",
      "runner_version" => "dev+abc1234",
      "download_url" => server.url <> "/downloads/runner/"
    }

    test = self()

    opts = [
      argv: @argv,
      auto_update: false,
      platform_url: server.url,
      env: %{"__BURRITO_BIN_PATH" => bin},
      tty?: true,
      gets: fn prompt ->
        send(test, {:asked, prompt})
        raise "the test did not expect a question"
      end,
      relaunch: fn bin, argv, mode ->
        send(test, {:relaunch, bin, argv, mode})
        :relaunched
      end
    ]

    %{server: server, bin: bin, bin_dir: bin_dir, refusal: refusal, opts: opts}
  end

  defp answering(opts, answer) do
    test = self()

    Keyword.put(opts, :gets, fn prompt ->
      send(test, {:asked, prompt})
      answer
    end)
  end

  test "the question names the runner's version and the one the platform asks for" do
    prompt = Update.prompt(%{"version" => "dev+def5678", "runner_version" => "dev+abc1234"})

    assert prompt =~
             "Este runner está na versão dev+abc1234 e a plataforma pede a versão dev+def5678 do runner."

    refute prompt =~ "a plataforma está na"

    assert prompt =~ "Baixar e instalar a versão dev+def5678 agora? [S/n]"
  end

  test "the message says which runner's version the platform asks for" do
    message =
      Update.message(%{
        "version" => "dev+def5678",
        "runner_version" => "dev+abc1234",
        "download_url" => "https://pipemaestro.example/downloads/runner/"
      })

    assert message =~
             "Este runner está na versão dev+abc1234, e a plataforma pede a versão dev+def5678 do runner"

    refute message =~ "a plataforma está na"
    assert message =~ "https://pipemaestro.example/downloads/runner/"
  end

  for answer <- ["\n", "s\n", "S\n", "sim\n"] do
    test "--no-auto-update: answering #{inspect(answer)} downloads, replaces and runs the same command again",
         ctx do
      opts = answering(ctx.opts, unquote(answer))

      assert Update.handle(ctx.refusal, opts) == :relaunched

      assert_received {:asked, prompt}
      assert prompt =~ "Baixar e instalar a versão dev+def5678 agora? [S/n]"
      assert File.read!(ctx.bin) == @new
      assert_received {:relaunch, bin, @argv, :interactive}
      assert bin == ctx.bin
    end
  end

  for answer <- ["n\n", "N\n", "não\n", "nao\n"] do
    test "--no-auto-update: answering #{inspect(answer)} keeps the message and downloads nothing",
         ctx do
      opts = answering(ctx.opts, unquote(answer))

      assert Update.handle(ctx.refusal, opts) == {:fail, Update.message(ctx.refusal)}

      assert_received {:asked, _prompt}
      assert File.read!(ctx.bin) == @old
      assert DownloadServer.requests(ctx.server) == []
      refute_received {:relaunch, _bin, _argv, _mode}
    end
  end

  test "--no-auto-update: an input that ends (Ctrl+D) is a no", ctx do
    opts = answering(ctx.opts, :eof)

    assert Update.handle(ctx.refusal, opts) == {:fail, Update.message(ctx.refusal)}
    assert DownloadServer.requests(ctx.server) == []
  end

  test "--no-auto-update without a terminal does not ask: the message", ctx do
    opts = Keyword.put(ctx.opts, :tty?, false)

    assert Update.handle(ctx.refusal, opts) == {:fail, Update.message(ctx.refusal)}

    refute_received {:asked, _prompt}
    assert File.read!(ctx.bin) == @old
    assert DownloadServer.requests(ctx.server) == []
  end

  test "by default, without a terminal, it updates without asking, for the service manager",
       ctx do
    opts = ctx.opts |> Keyword.put(:tty?, false) |> Keyword.delete(:auto_update)

    assert Update.handle(ctx.refusal, opts) == :relaunched

    refute_received {:asked, _prompt}
    assert File.read!(ctx.bin) == @new
    assert_received {:relaunch, bin, @argv, :service}
    assert bin == ctx.bin
  end

  test "by default, in a terminal, it updates without asking and runs again there", ctx do
    opts = Keyword.delete(ctx.opts, :auto_update)

    assert Update.handle(ctx.refusal, opts) == :relaunched

    refute_received {:asked, _prompt}
    assert File.read!(ctx.bin) == @new
    assert_received {:relaunch, _bin, @argv, :interactive}
  end

  test "--auto-update without a terminal updates without asking, for the service manager",
       ctx do
    opts = ctx.opts |> Keyword.put(:tty?, false) |> Keyword.put(:auto_update, true)

    assert Update.handle(ctx.refusal, opts) == :relaunched

    refute_received {:asked, _prompt}
    assert File.read!(ctx.bin) == @new
    assert_received {:relaunch, _bin, @argv, :service}
  end

  test "--auto-update in a terminal updates without asking and runs again there", ctx do
    opts = Keyword.put(ctx.opts, :auto_update, true)

    assert Update.handle(ctx.refusal, opts) == :relaunched

    refute_received {:asked, _prompt}
    assert_received {:relaunch, _bin, @argv, :interactive}
  end

  test "under Mix or a release (no single binary) it is the message, whatever the option",
       ctx do
    for env <- [%{}, %{"RELEASE_ROOT" => "/rel"}],
        auto_update <- [nil, true, false] do
      opts =
        ctx.opts
        |> Keyword.put(:env, env)
        |> Keyword.delete(:auto_update)
        |> then(&if(auto_update == nil, do: &1, else: Keyword.put(&1, :auto_update, auto_update)))

      assert Update.handle(ctx.refusal, opts) == {:fail, Update.message(ctx.refusal)}
    end

    refute_received {:asked, _prompt}
    assert DownloadServer.requests(ctx.server) == []
  end

  test "a download_url on another origin is not downloaded: today's message", ctx do
    refusal = Map.put(ctx.refusal, "download_url", "https://cdn.exemplo.com/runner/")
    opts = answering(ctx.opts, "s\n")

    assert {:fail, message} = Update.handle(refusal, opts)
    assert message =~ Update.message(refusal)
    assert File.read!(ctx.bin) == @old
    refute_received {:relaunch, _bin, _argv, _mode}
  end

  test "with a marker, an update leaves what happened for the next start", ctx do
    marker = Path.join(ctx.bin_dir, "update.json")
    opts = ctx.opts |> Keyword.delete(:auto_update) |> Keyword.put(:marker, marker)

    assert Update.handle(ctx.refusal, opts) == :relaunched
    assert {:applied, %{"to" => "dev+def5678", "from" => _from}} = Update.take_marker(marker)
    assert Update.take_marker(marker) == nil

    DownloadServer.behave(ctx.server, "SHA256SUMS", :missing)
    assert {:fail, _message} = Update.handle(ctx.refusal, opts)
    assert {:failed, %{"reason" => reason}} = Update.take_marker(marker)
    assert reason =~ "404"
  end

  test "a failed download says why, keeps the binary and does not run again", ctx do
    DownloadServer.behave(ctx.server, "SHA256SUMS", :missing)
    opts = answering(ctx.opts, "s\n")

    assert {:fail, message} = Update.handle(ctx.refusal, opts)
    assert message =~ "404"
    assert message =~ Update.message(ctx.refusal)
    assert File.read!(ctx.bin) == @old
    refute_received {:relaunch, _bin, _argv, _mode}
  end

  if System.cmd("id", ["-u"]) == {"0\n", 0}, do: @tag(skip: "roda como root")

  test "a directory it cannot write to: the path and the commands to do it by hand", ctx do
    File.chmod!(ctx.bin_dir, 0o555)
    on_exit(fn -> File.chmod(ctx.bin_dir, 0o755) end)
    opts = answering(ctx.opts, "s\n")

    assert {:fail, message} = Update.handle(ctx.refusal, opts)

    assert message =~ ctx.bin_dir
    assert message =~ "curl"
    assert message =~ "SHA256SUMS"
    assert message =~ "shasum -a 256 -c"
    assert message =~ "chmod"
    assert message =~ "mv"
    refute message =~ "sudo"
    assert File.read!(ctx.bin) == @old
    refute_received {:relaunch, _bin, _argv, _mode}
  end
end
