defmodule PipeMaestroRunner.SelfUpdateTest do
  use ExUnit.Case, async: true

  alias PipeMaestroProtocol.Downloads
  alias PipeMaestroRunner.SelfUpdate
  alias PipeMaestroRunner.Test.DownloadServer

  @moduletag :tmp_dir

  @old "#!/bin/sh\necho vVELHO\n"
  @new "#!/bin/sh\necho vNOVO\n"

  describe "target/2 and target/0" do
    test "maps the system's architecture to the deploy's target" do
      assert SelfUpdate.target({:unix, :darwin}, ~c"aarch64-apple-darwin23.4.0") ==
               {:ok, "macos_arm64"}

      assert SelfUpdate.target({:unix, :darwin}, ~c"x86_64-apple-darwin22.1.0") ==
               {:ok, "macos_x86_64"}

      assert SelfUpdate.target({:unix, :linux}, ~c"x86_64-pc-linux-gnu") ==
               {:ok, "linux_x86_64"}

      assert SelfUpdate.target({:unix, :linux}, ~c"aarch64-unknown-linux-gnu") ==
               {:ok, "linux_arm64"}

      assert SelfUpdate.target({:win32, :nt}, ~c"win32") == {:error, :unsupported_platform}

      assert SelfUpdate.target({:unix, :freebsd}, ~c"amd64-portbld-freebsd14.0") ==
               {:error, :unsupported_platform}
    end

    test "this machine's target is one the deploy publishes" do
      assert {:ok, target} = SelfUpdate.target()
      assert target in Downloads.targets()
    end
  end

  describe "urls/3" do
    test "the binary and the checksums inside download_url, on the platform's origin" do
      assert SelfUpdate.urls(
               "https://pipemaestro.app",
               "https://pipemaestro.app/downloads/runner/",
               "linux_arm64"
             ) ==
               {:ok,
                %{
                  binary: "https://pipemaestro.app/downloads/runner/pipemaestro_linux_arm64",
                  checksums: "https://pipemaestro.app/downloads/runner/SHA256SUMS"
                }}

      assert {:ok, %{binary: "http://localhost:4000/downloads/runner/pipemaestro_macos_arm64"}} =
               SelfUpdate.urls(
                 "http://localhost:4000",
                 "http://localhost:4000/downloads/runner",
                 "macos_arm64"
               )

      assert {:ok, %{checksums: "http://127.0.0.1:4100/downloads/runner/SHA256SUMS"}} =
               SelfUpdate.urls(
                 "http://127.0.0.1:4100/",
                 "http://127.0.0.1:4100/downloads/runner/",
                 "macos_arm64"
               )
    end

    test "without download_url, the platform's own downloads directory" do
      assert {:ok, %{binary: "https://pipemaestro.app/downloads/runner/pipemaestro_linux_x86_64"}} =
               SelfUpdate.urls("https://pipemaestro.app", nil, "linux_x86_64")
    end

    test "refuses another origin, another port or http to a host that is not this machine" do
      for {platform, download} <- [
            {"https://pipemaestro.app", "https://cdn.exemplo.com/runner/"},
            {"https://pipemaestro.app", "http://pipemaestro.app/downloads/runner/"},
            {"https://pipemaestro.app", "https://pipemaestro.app:8443/downloads/runner/"},
            {"http://localhost:4000", "http://localhost:4001/downloads/runner/"},
            {"http://plataforma.lan", "http://plataforma.lan/downloads/runner/"},
            {"https://pipemaestro.app", "https://pipemaestro.app.evil.com/downloads/runner/"}
          ] do
        assert SelfUpdate.urls(platform, download, "linux_x86_64") == {:error, :foreign_origin},
               "#{platform} → #{download}"
      end
    end
  end

  describe "install/2" do
    setup %{tmp_dir: tmp} do
      {:ok, target} = SelfUpdate.target()
      name = Downloads.binary_name(target)

      served = Path.join(tmp, "served")
      File.mkdir_p!(served)
      DownloadServer.publish(served, name, @new)
      server = DownloadServer.start(served)

      bin_dir = Path.join(tmp, "bin")
      File.mkdir_p!(bin_dir)
      bin = Path.join(bin_dir, "pipemaestro")
      File.write!(bin, @old)
      File.chmod!(bin, 0o755)

      {:ok, urls} =
        SelfUpdate.urls(server.url, server.url <> "/downloads/runner/", target)

      opts = [urls: urls, target: target, progress: fn _percent -> :ok end]

      %{server: server, served: served, name: name, bin: bin, bin_dir: bin_dir, opts: opts}
    end

    test "replaces the binary with the one served, executable, leaving nothing behind", ctx do
      inode = File.stat!(ctx.bin).inode

      assert SelfUpdate.install(ctx.bin, ctx.opts) == :ok

      assert File.read!(ctx.bin) == @new
      assert File.stat!(ctx.bin).inode != inode
      assert Bitwise.band(File.stat!(ctx.bin).mode, 0o777) == 0o755
      assert {"vNOVO\n", 0} = System.cmd(ctx.bin, [])
      assert File.ls!(ctx.bin_dir) == ["pipemaestro"]
    end

    test "reports the download's progress", ctx do
      test = self()
      opts = Keyword.put(ctx.opts, :progress, &send(test, {:progress, &1}))

      assert SelfUpdate.install(ctx.bin, opts) == :ok
      assert_received {:progress, 100}
    end

    test "a checksum that does not match keeps the binary as it was", ctx do
      DownloadServer.publish(
        ctx.served,
        ctx.name,
        @new,
        String.duplicate("0", 64) <> "  " <> ctx.name <> "\n"
      )

      assert SelfUpdate.install(ctx.bin, ctx.opts) == {:error, :checksum_mismatch}
      assert_untouched(ctx)
    end

    test "a target missing from SHA256SUMS keeps the binary as it was", ctx do
      DownloadServer.publish(
        ctx.served,
        ctx.name,
        @new,
        String.duplicate("0", 64) <> "  pipemaestro_outro\n"
      )

      assert SelfUpdate.install(ctx.bin, ctx.opts) == {:error, {:missing_checksum, ctx.name}}
      assert_untouched(ctx)
    end

    test "a binary that is not there (404) keeps the binary as it was", ctx do
      DownloadServer.behave(ctx.server, ctx.name, :missing)

      assert {:error, {:http_status, 404, _url}} = SelfUpdate.install(ctx.bin, ctx.opts)
      assert_untouched(ctx)
    end

    test "SHA256SUMS that is not there keeps the binary as it was", ctx do
      DownloadServer.behave(ctx.server, "SHA256SUMS", :missing)

      assert {:error, {:http_status, 404, _url}} = SelfUpdate.install(ctx.bin, ctx.opts)
      assert_untouched(ctx)
      assert DownloadServer.requests(ctx.server) == ["SHA256SUMS"]
    end

    test "a download cut in the middle keeps the binary as it was", ctx do
      DownloadServer.publish(ctx.served, ctx.name, @new <> String.duplicate("#\n", 50_000))
      DownloadServer.behave(ctx.server, ctx.name, :cut)

      assert {:error, _reason} = SelfUpdate.install(ctx.bin, ctx.opts)
      assert_untouched(ctx)
    end

    # Root writes anywhere, so the directory's mode cannot stop it.
    if System.cmd("id", ["-u"]) == {"0\n", 0}, do: @tag(skip: "roda como root")

    test "a directory it cannot write to: says which, and changes nothing", ctx do
      inode = File.stat!(ctx.bin).inode
      File.chmod!(ctx.bin_dir, 0o555)
      on_exit(fn -> File.chmod(ctx.bin_dir, 0o755) end)

      assert SelfUpdate.install(ctx.bin, ctx.opts) == {:error, {:not_writable, ctx.bin_dir}}

      assert File.read!(ctx.bin) == @old
      assert File.stat!(ctx.bin).inode == inode
      assert File.ls!(ctx.bin_dir) == ["pipemaestro"]
      assert DownloadServer.requests(ctx.server) == []
    end

    defp assert_untouched(ctx) do
      assert File.read!(ctx.bin) == @old
      assert Bitwise.band(File.stat!(ctx.bin).mode, 0o777) == 0o755
      assert File.ls!(ctx.bin_dir) == ["pipemaestro"]
    end
  end

  test "clean_stale/1 removes temporary files an interrupted update left", %{tmp_dir: tmp} do
    bin = Path.join(tmp, "pipemaestro")
    File.write!(bin, @old)
    File.write!(Path.join(tmp, ".pipemaestro.update-abc123"), "metade")
    File.write!(Path.join(tmp, ".pipemaestro.update-zzz"), "metade")
    File.write!(Path.join(tmp, "outro"), "fica")

    assert SelfUpdate.clean_stale(bin) == :ok
    assert Enum.sort(File.ls!(tmp)) == ["outro", "pipemaestro"]
  end

  describe "relaunch" do
    test "interactive: runs the new binary with the same arguments and returns its status",
         %{tmp_dir: tmp} do
      out = Path.join(tmp, "out")
      bin = Path.join(tmp, "pipemaestro")

      File.write!(bin, """
      #!/bin/sh
      echo "$* [${__BURRITO_BIN_PATH:-}] [${RELEASE_ROOT:-}]" > "#{out}"
      exit 3
      """)

      File.chmod!(bin, 0o755)

      assert SelfUpdate.relaunch(bin, ["start", "--root", "/x"], :interactive) == 3
      assert File.read!(out) == "start --root /x [] []\n"
    end

    test "service: leaves it to the service manager, exiting 0" do
      test = self()
      halt = fn status -> send(test, {:halt, status}) end

      SelfUpdate.relaunch("/opt/pipemaestro", ["start", "--auto-update"], :service, halt: halt)
      assert_received {:halt, 0}
    end

    test "the new binary does not inherit the old one's unpacked release" do
      env = %{
        "__BURRITO_BIN_PATH" => "/opt/pipemaestro",
        "__BURRITO" => "1",
        "RELEASE_ROOT" => "/tmp/burrito/x",
        "RELEASE_NODE" => "pm",
        "ROOTDIR" => "/tmp/burrito/x",
        "BINDIR" => "/tmp/burrito/x/erts/bin",
        "EMU" => "beam",
        "PROGNAME" => "erl",
        "HOME" => "/home/ana",
        "PATH" => "/usr/bin"
      }

      unset = SelfUpdate.child_env(env)

      assert Enum.sort(unset) ==
               Enum.sort(
                 for name <- ~w(__BURRITO_BIN_PATH __BURRITO RELEASE_ROOT RELEASE_NODE ROOTDIR
                                BINDIR EMU PROGNAME),
                     do: {String.to_charlist(name), false}
               )
    end
  end
end
