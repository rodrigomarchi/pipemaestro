defmodule PipeMaestroProtocol.Version.ImageBuildTest do
  # The control plane's image gets its versions from the root Makefile
  # (`make image`, `make cp.version`, `make runner.version`) and refuses to
  # build without them (Dockerfile). The Makefile runs here for real, with a
  # fake `mix` (the versions it prints and its exit status) and a fake
  # `docker` (that only records it ran) first on the PATH.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @root Path.expand("../../../../..", __DIR__)

  @fake_mix """
  #!/bin/sh
  case "$*" in
    *runner.version*) printf '%s\\n' "$FAKE_RUNNER_OUT"; exit "${FAKE_RUNNER_STATUS:-0}" ;;
    *) printf '%s\\n' "$FAKE_CP_OUT"; exit "${FAKE_CP_STATUS:-0}" ;;
  esac
  """

  @fake_docker """
  #!/bin/sh
  printf '%s\\n' "$*" >> "$DOCKER_LOG"
  """

  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    for {name, script} <- [{"mix", @fake_mix}, {"docker", @fake_docker}] do
      path = Path.join(bin, name)
      File.write!(path, script)
      File.chmod!(path, 0o755)
    end

    %{bin: bin, docker_log: Path.join(dir, "docker.log")}
  end

  defp make(ctx, target, fakes) do
    env =
      [
        {"PATH", ctx.bin <> ":" <> System.get_env("PATH", "")},
        {"DOCKER_LOG", ctx.docker_log},
        {"CP_VERSION", nil},
        {"RUNNER_VERSION", nil},
        {"MAKEFLAGS", nil},
        {"MAKELEVEL", nil}
      ] ++ Enum.map(fakes, fn {name, value} -> {name, value} end)

    System.cmd("make", ["-s", "--no-print-directory", target],
      cd: @root,
      env: env,
      stderr_to_stdout: true
    )
  end

  defp docker_runs(ctx) do
    case File.read(ctx.docker_log) do
      {:ok, log} -> String.split(log, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp versions(cp, runner),
    do: [{"FAKE_CP_OUT", cp}, {"FAKE_RUNNER_OUT", runner}]

  describe "make image with versions in the scheme" do
    for {cp, runner} <- [
          {"2026-11-04.01", "2026-11-04.01"},
          {"2026-11-04.01+dev.abc1234", "2026-11-03.100+dev.0f1e2d3"},
          {"dev+abc1234", "dev+0f1e2d3"}
        ] do
      test "builds with CP_VERSION=#{cp} and RUNNER_VERSION=#{runner}", ctx do
        {output, status} = make(ctx, "image", versions(unquote(cp), unquote(runner)))

        assert status == 0, output
        assert output =~ unquote(cp)
        assert output =~ unquote(runner)

        assert [run] = docker_runs(ctx)
        assert run =~ "build"
        assert run =~ "--build-arg CP_VERSION=#{unquote(cp)} "
        assert run =~ "--build-arg RUNNER_VERSION=#{unquote(runner)} "
        assert run =~ "-t pipemaestro"
      end
    end

    test "takes the last line mix prints, after what it compiles", ctx do
      fakes =
        versions(
          "Compiling 3 files (.ex)\nGenerated pipe_maestro_protocol app\n2026-11-04.02+dev.abc1234",
          "Compiling 1 file (.ex)\n2026-11-04.01"
        )

      {output, status} = make(ctx, "image", fakes)

      assert status == 0, output
      assert [run] = docker_runs(ctx)
      assert run =~ "--build-arg CP_VERSION=2026-11-04.02+dev.abc1234 "
      assert run =~ "--build-arg RUNNER_VERSION=2026-11-04.01 "
    end
  end

  describe "make image when a version cannot be computed" do
    test "stops before docker when the control plane's fails", ctx do
      fakes =
        versions("** (SyntaxError) lib/x.ex:1: syntax error", "2026-11-04.01") ++
          [{"FAKE_CP_STATUS", "1"}]

      {output, status} = make(ctx, "image", fakes)

      assert status != 0
      assert output =~ "Não consegui calcular a versão do control plane"
      assert output =~ "SyntaxError"
      assert docker_runs(ctx) == []
    end

    test "stops before docker when the runner's fails", ctx do
      fakes =
        versions("2026-11-04.01", "** (CompileError) lib/y.ex:2: undefined") ++
          [{"FAKE_RUNNER_STATUS", "1"}]

      {output, status} = make(ctx, "image", fakes)

      assert status != 0
      assert output =~ "Não consegui calcular a versão do runner"
      assert output =~ "CompileError"
      assert docker_runs(ctx) == []
    end
  end

  describe "make image with a version outside the scheme" do
    for bad <- [
          "",
          "dev+unknown",
          "2026-11-04.01+dev.unknown",
          "** (CompileError) lib/x.ex:1",
          "2026-11-4.01",
          "2026-11-04.1",
          "0.1.0",
          "dev+ABC123"
        ] do
      test "refuses the control plane's #{inspect(bad)}", ctx do
        {output, status} = make(ctx, "image", versions(unquote(bad), "2026-11-04.01"))

        assert status != 0
        assert output =~ "versão do control plane"
        assert docker_runs(ctx) == []
      end

      test "refuses the runner's #{inspect(bad)}", ctx do
        {output, status} = make(ctx, "image", versions("2026-11-04.01", unquote(bad)))

        assert status != 0
        assert output =~ "versão do runner"
        assert docker_runs(ctx) == []
      end
    end
  end

  describe "the version targets" do
    test "cp.version fails when mix fails", ctx do
      fakes = [{"FAKE_CP_OUT", "** (SyntaxError) lib/x.ex:1"}, {"FAKE_CP_STATUS", "1"}]

      {_output, status} = make(ctx, "cp.version", fakes)

      assert status != 0
    end

    test "runner.version fails when mix fails", ctx do
      fakes = [{"FAKE_RUNNER_OUT", "** (SyntaxError) lib/y.ex:1"}, {"FAKE_RUNNER_STATUS", "1"}]

      {_output, status} = make(ctx, "runner.version", fakes)

      assert status != 0
    end

    test "cp.version prints only the last line when mix succeeds", ctx do
      fakes = [{"FAKE_CP_OUT", "Compiling 2 files (.ex)\ndev+abc1234"}]

      assert {"dev+abc1234\n", 0} = make(ctx, "cp.version", fakes)
    end
  end

  describe "the Makefile's version expressions" do
    test "the release expression is written once, shared by image and runner.release" do
      makefile = File.read!(Path.join(@root, "Makefile"))

      occurrences =
        makefile
        |> String.split("[0-9]{4}-[0-9]{2}-[0-9]{2}")
        |> length()
        |> Kernel.-(1)

      assert occurrences == 1
    end
  end

  describe "the Dockerfile" do
    setup do
      %{dockerfile: File.read!(Path.join(@root, "Dockerfile"))}
    end

    test "declares the local-build escape hatch", %{dockerfile: dockerfile} do
      assert dockerfile =~ ~r/^ARG ALLOW_UNVERSIONED/m
    end

    test "refuses to build without the versions before mix compile", %{dockerfile: dockerfile} do
      [before_compile, _after] = String.split(dockerfile, ~r/^RUN mix compile/m, parts: 2)
      [_head, build_stage] = String.split(before_compile, ~r/^FROM .* AS build$/m, parts: 2)

      guard =
        build_stage
        |> String.split(~r/^RUN /m)
        |> Enum.find(&(&1 =~ "$ALLOW_UNVERSIONED"))

      assert guard, "no RUN in the build stage checks ALLOW_UNVERSIONED before mix compile"
      assert guard =~ "CP_VERSION"
      assert guard =~ "RUNNER_VERSION"
      assert guard =~ "make image"
      assert guard =~ "exit 1"
    end
  end
end
