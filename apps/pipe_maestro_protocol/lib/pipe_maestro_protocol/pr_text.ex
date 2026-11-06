defmodule PipeMaestroProtocol.PrText do
  @moduledoc """
  The platform's part of a pull request's text, and only that: the runner
  writes it when it keeps the pull request, the control plane when it does.

  - **Description:** the platform writes one block, between
    `<!-- pipemaestro:inicio -->` and `<!-- pipemaestro:fim -->`. Updating
    the pull request replaces that block and keeps everything else as people
    or the agent wrote it; a description without the block gets it at the end.
  - **Title:** written once, when the platform opens the pull request. Later
    deliveries only add or take off the draft prefix (where a draft is a
    title prefix, as on a Forgejo), keeping the title as it is.
  """

  @start "<!-- pipemaestro:inicio -->"
  @finish "<!-- pipemaestro:fim -->"

  @doc "`block` between the platform's markers."
  @spec wrap(String.t()) :: String.t()
  def wrap(block), do: @start <> "\n" <> String.trim(block) <> "\n" <> @finish

  @doc """
  `body` with the platform's block replaced by `block`, or with it added at
  the end when `body` has none.
  """
  @spec body(String.t() | nil, String.t()) :: String.t()
  def body(body, block) do
    body = body || ""

    case String.split(body, @start, parts: 2) do
      [before, rest] ->
        after_block =
          case String.split(rest, @finish, parts: 2) do
            [_old, tail] -> tail
            [_unterminated] -> ""
          end

        before <> wrap(block) <> after_block

      [_none] ->
        if String.trim(body) == "",
          do: wrap(block),
          else: String.trim_trailing(body) <> "\n\n" <> wrap(block)
    end
  end

  @doc "`title` with the draft `prefix` added (`draft?`) or taken off."
  @spec title(String.t(), boolean(), String.t()) :: String.t()
  def title(title, draft?, prefix) do
    bare =
      if String.starts_with?(title, prefix),
        do: String.replace_prefix(title, prefix, ""),
        else: title

    if draft?, do: prefix <> bare, else: bare
  end
end
