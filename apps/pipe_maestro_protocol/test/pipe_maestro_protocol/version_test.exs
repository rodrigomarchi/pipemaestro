defmodule PipeMaestroProtocol.VersionTest do
  use ExUnit.Case, async: true

  alias PipeMaestroProtocol.Version

  @today ~D[2026-11-04]

  describe "format/2" do
    test "pads the day's number to two digits, and grows past 99" do
      assert Version.format(@today, 1) == "2026-11-04.01"
      assert Version.format(@today, 12) == "2026-11-04.12"
      assert Version.format(@today, 100) == "2026-11-04.100"
    end
  end

  describe "parse_tag/1" do
    test "reads release tags" do
      assert Version.parse_tag("runner-2026-11-04.01") == {:ok, {@today, 1}}
      assert Version.parse_tag("runner-2026-11-04.100") == {:ok, {@today, 100}}
    end

    test "ignores tags in any other format" do
      for tag <- ~w(v1.2.3 runner-2026-11-04 runner-2026-11-04.1 runner-2026-13-01.01
                    runner-2026-02-30.01 runner-2026-11-04.00 runner-2026-11-04.01-rc
                    foo-2026-11-04.01 2026-11-04.01) do
        assert Version.parse_tag(tag) == :error, "expected #{tag} to be ignored"
      end
    end
  end

  describe "parse/1" do
    test "a release, a development build on top of one, or a build with no release" do
      assert Version.parse("2026-11-04.02") == {:release, @today, 2}
      assert Version.parse("2026-11-04.02+dev.abc1234") == {:dev, {@today, 2}, "abc1234"}
      assert Version.parse("dev+abc1234") == {:dev, nil, "abc1234"}
      assert Version.parse("dev+unknown") == {:dev, nil, "unknown"}
    end

    test "anything else is unknown" do
      for version <- ["0.1.0", "", "2026-11-04", "2026-13-04.01", "2026-11-04.1", "latest"] do
        assert Version.parse(version) == :unknown, "expected #{inspect(version)} to be unknown"
      end
    end
  end

  describe "next/2" do
    test "the day's first release is .01" do
      assert Version.next([], @today) == "2026-11-04.01"
      assert Version.next(["runner-2026-11-03.05"], @today) == "2026-11-04.01"
    end

    test "increments the day's highest number" do
      assert Version.next(["runner-2026-11-04.01"], @today) == "2026-11-04.02"

      assert Version.next(["runner-2026-11-04.01", "runner-2026-11-04.03"], @today) ==
               "2026-11-04.04"
    end

    test "compares the number numerically: .09 is followed by .10, .10 by .11" do
      assert Version.next(["runner-2026-11-04.09"], @today) == "2026-11-04.10"

      assert Version.next(["runner-2026-11-04.10", "runner-2026-11-04.09"], @today) ==
               "2026-11-04.11"

      assert Version.next(["runner-2026-11-04.99"], @today) == "2026-11-04.100"
    end

    test "tags in other formats do not count" do
      tags = ~w(v1.2.3 runner-2026-11-04 runner-2026-11-04.7 runner-2026-11-04.08-rc
                foo-2026-11-04.09 runner-2026-13-04.01)

      assert Version.next(tags, @today) == "2026-11-04.01"
    end
  end

  describe "describe/3" do
    test "a build at a release tag is that release" do
      assert Version.describe(["runner-2026-11-04.02"], ["runner-2026-11-04.02"], "abc1234") ==
               "2026-11-04.02"
    end

    test "with more than one release at the commit, the highest" do
      head = ["runner-2026-11-04.02", "runner-2026-11-04.10", "v1.0.0"]
      assert Version.describe(head, head, "abc1234") == "2026-11-04.10"
    end

    test "a build after a release is a development build on top of the latest one" do
      reachable = ["runner-2026-11-03.01", "runner-2026-11-04.02", "v9.9.9"]

      assert Version.describe([], reachable, "abc1234") == "2026-11-04.02+dev.abc1234"
      assert Version.describe(["v1.0.0"], reachable, "abc1234") == "2026-11-04.02+dev.abc1234"
    end

    test "with no release at all, dev and the commit" do
      assert Version.describe([], [], "abc1234") == "dev+abc1234"
      assert Version.describe([], ["v1.0.0"], "abc1234") == "dev+abc1234"
    end

    test "without a commit, dev+unknown" do
      assert Version.describe([], [], nil) == "dev+unknown"
    end
  end

  describe "compare/2" do
    test "by date, then by the day's number" do
      assert Version.compare("2026-11-04.01", "2026-11-04.02") == :lt
      assert Version.compare("2026-11-04.02", "2026-11-04.02") == :eq
      assert Version.compare("2026-11-04.10", "2026-11-04.09") == :gt
      assert Version.compare("2026-11-05.01", "2026-11-04.99") == :gt
      assert Version.compare("2025-12-31.50", "2026-01-01.01") == :lt
    end
  end

  describe "outdated?/2" do
    test "a release older than the reference is outdated" do
      assert Version.outdated?("2026-11-04.01", "2026-11-04.02")
      assert Version.outdated?("2026-11-03.09", "2026-11-04.01")
      assert Version.outdated?("2026-11-04.09", "2026-11-04.10")
    end

    test "the same release or a newer one is not" do
      refute Version.outdated?("2026-11-04.02", "2026-11-04.02")
      refute Version.outdated?("2026-11-04.03", "2026-11-04.02")
      refute Version.outdated?("2026-11-05.01", "2026-11-04.99")
    end

    test "a development build of the reference is compared by its release" do
      assert Version.outdated?("2026-11-04.01", "2026-11-04.02+dev.abc1234")
      refute Version.outdated?("2026-11-04.02", "2026-11-04.02+dev.abc1234")
    end

    test "a development runner is never outdated" do
      refute Version.outdated?("2026-11-04.01+dev.abc1234", "2026-11-04.02")
      refute Version.outdated?("dev+abc1234", "2026-11-04.02")
    end

    test "an unknown or missing runner version is not marked" do
      refute Version.outdated?("0.1.0", "2026-11-04.02")
      refute Version.outdated?(nil, "2026-11-04.02")
      refute Version.outdated?("", "2026-11-04.02")
    end

    test "a reference with no release marks nobody" do
      refute Version.outdated?("2026-11-04.01", "dev+abc1234")
      refute Version.outdated?("2026-11-04.01", "dev+unknown")
      refute Version.outdated?("2026-11-04.01", "0.1.0")
    end
  end
end
