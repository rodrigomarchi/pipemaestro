defmodule PipeMaestroProtocol.Text do
  @moduledoc """
  Cuts text to a size in bytes without splitting a UTF-8 character, as every
  limit of the protocol counts bytes (an event's text, a command's output,
  what the agent is writing).
  """

  @ellipsis "…"

  @doc """
  The start of `text`, at most `max` bytes, ending in "…" when it was cut.
  """
  @spec truncate(String.t(), pos_integer()) :: String.t()
  def truncate(text, max) when byte_size(text) <= max, do: text

  def truncate(text, max) do
    keep = max - byte_size(@ellipsis)
    text |> binary_part(0, keep) |> valid_utf8() |> Kernel.<>(@ellipsis)
  end

  @doc "The end of `text`, at most `max` bytes."
  @spec tail(String.t(), pos_integer()) :: String.t()
  def tail(text, max) when byte_size(text) <= max, do: text
  def tail(text, max), do: text |> binary_part(byte_size(text) - max, max) |> valid_utf8()

  @doc """
  `data` without a character split where it was cut: continuation bytes at the
  start and an incomplete or invalid sequence at the end go.
  """
  @spec valid_utf8(binary()) :: String.t()
  def valid_utf8(<<0b10::2, _bits::6, rest::binary>>), do: valid_utf8(rest)

  def valid_utf8(data) do
    case :unicode.characters_to_binary(data) do
      binary when is_binary(binary) -> binary
      {_incomplete_or_error, valid, _rest} -> valid
    end
  end
end
