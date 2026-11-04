defmodule PipeMaestroProtocol.DownloadsTest do
  use ExUnit.Case, async: true

  alias PipeMaestroProtocol.Downloads

  test "the targets the deploy publishes a binary for" do
    assert Downloads.targets() == ["macos_arm64", "macos_x86_64", "linux_x86_64", "linux_arm64"]
  end

  test "each target's binary and the checksums file, as names inside download_url" do
    assert Downloads.binary_name("linux_arm64") == "pipemaestro_linux_arm64"
    assert Downloads.binary_name("macos_arm64") == "pipemaestro_macos_arm64"
    assert Downloads.checksums_name() == "SHA256SUMS"
  end

  test "reads a SHA256SUMS in sha256sum's format, skipping lines out of shape" do
    hash_a = String.duplicate("a", 64)
    hash_b = String.duplicate("B", 64)

    content = """
    #{hash_a}  pipemaestro_linux_x86_64
    #{hash_b} *pipemaestro_macos_arm64

    não é uma linha de checksum
    1234  pipemaestro_curto
    """

    assert Downloads.parse_checksums(content) == %{
             "pipemaestro_linux_x86_64" => hash_a,
             "pipemaestro_macos_arm64" => String.downcase(hash_b)
           }

    assert Downloads.parse_checksums("") == %{}
  end
end
