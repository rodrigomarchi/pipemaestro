defmodule PipeMaestroProtocol.TextTest do
  use ExUnit.Case, async: true

  alias PipeMaestroProtocol.Text

  test "truncate keeps the start within the bytes, never splitting a character" do
    assert Text.truncate("curto", 10) == "curto"

    cut = Text.truncate(String.duplicate("ç", 10), 10)
    assert byte_size(cut) <= 10
    assert String.valid?(cut)
    assert String.ends_with?(cut, "…")
  end

  test "tail keeps the end within the bytes, starting at a character" do
    assert Text.tail("curto", 10) == "curto"

    tail = Text.tail("aaaaaçççç", 7)
    assert byte_size(tail) <= 7
    assert String.valid?(tail)
    assert String.ends_with?(tail, "ççç")
  end

  test "valid_utf8 drops a character split at either end" do
    <<_first, split_start::binary>> = "çok"
    assert Text.valid_utf8(split_start) == "ok"

    <<split_end::binary-size(3), _rest::binary>> = "okç"
    assert Text.valid_utf8(split_end) == "ok"
  end
end
