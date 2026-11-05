defmodule PipeMaestroWeb.StaticBrandTest do
  @moduledoc """
  The symbol shipped as static files in `priv/static/`: the color and mono SVGs,
  the simplified favicon and the `.ico` rasterized from it.
  """
  use ExUnit.Case, async: true

  @violet "#a78bfa"
  @cyan "#38bdf8"
  @dark 0.08

  defp path(file), do: Application.app_dir(:pipe_maestro_web, Path.join("priv/static", file))

  defp svg(file) do
    source = File.read!(path(file))
    {source, LazyHTML.from_document(source)}
  end

  defp attrs(doc, selector, attr), do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(attr)

  defp hex_colors(text), do: ~r/#[0-9a-fA-F]{6}\b/ |> Regex.scan(text) |> List.flatten()

  defp luminance("#" <> hex) do
    <<r::8, g::8, b::8>> = Base.decode16!(hex, case: :mixed)
    luminance({r, g, b})
  end

  defp luminance({r, g, b}) do
    [r, g, b]
    |> Enum.map(fn c ->
      c = c / 255
      if c <= 0.03928, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
    end)
    |> then(fn [r, g, b] -> 0.2126 * r + 0.7152 * g + 0.0722 * b end)
  end

  # The colors that paint the full-size background square: a literal fill or
  # the stops of the gradient it points to.
  defp background_colors(doc) do
    [fill] = attrs(doc, ~s(rect[width="32"][height="32"]), "fill")

    case Regex.run(~r/^url\(#(.+)\)$/, fill) do
      [_, id] -> attrs(doc, ~s([id="#{id}"] stop), "stop-color")
      nil -> [fill]
    end
  end

  defp assert_symbol(file) do
    {source, doc} = svg(file)

    assert attrs(doc, "svg", "viewBox") == ["0 0 32 32"]
    assert doc |> LazyHTML.query("svg > title") |> LazyHTML.text() == "PipeMaestro"
    assert Enum.empty?(LazyHTML.query(doc, "text"))
    assert Enum.empty?(LazyHTML.query(doc, "image"))
    assert Enum.empty?(LazyHTML.query(doc, "animate, animateTransform"))
    refute source =~ ~r/claude|anthropic/i

    {source, doc}
  end

  for file <- ~w(images/logo-mark.svg images/logo-mark-mono.svg images/favicon.svg) do
    test "#{file} draws its traces as circuit lines, with no curves" do
      {_source, doc} = assert_symbol(unquote(file))
      paths = attrs(doc, "path", "d")

      refute paths == []
      for d <- paths, do: refute(d =~ ~r/[CcSsQqTtAa]/, "curved path: #{d}")
    end
  end

  describe "images/logo-mark.svg" do
    test "is self-contained: neon traces on a dark square, no currentColor" do
      {source, doc} = assert_symbol("images/logo-mark.svg")

      refute source =~ "currentColor"

      for color <- background_colors(doc),
          do: assert(luminance(color) < @dark, "#{color} is not dark")

      assert String.downcase(source) =~ @violet
      assert String.downcase(source) =~ @cyan
    end

    test "glows through translucent copies of the traces, not a filter" do
      {source, doc} = assert_symbol("images/logo-mark.svg")

      refute source =~ "<filter"
      assert source =~ ~r/(stroke-)?opacity="0?\.\d+"/
      refute Enum.empty?(LazyHTML.query(doc, "circle"))
    end
  end

  describe "images/logo-mark-mono.svg" do
    test "draws only in currentColor, with no background nor glow" do
      {source, doc} = assert_symbol("images/logo-mark-mono.svg")

      assert source =~ "currentColor"
      assert hex_colors(source) == []
      refute source =~ "url("
      refute source =~ "opacity"
      assert Enum.empty?(LazyHTML.query(doc, "rect"))
    end

    test "keeps the three agent pads, the stage ring and the pull request dot" do
      {_source, doc} = assert_symbol("images/logo-mark-mono.svg")

      circles = attrs(doc, "circle", "cx")
      assert length(circles) >= 5
    end
  end

  describe "images/favicon.svg" do
    test "is the simplified symbol on a dark square with the cyan pull request dot" do
      {source, doc} = assert_symbol("images/favicon.svg")

      refute source =~ "currentColor"

      for color <- background_colors(doc),
          do: assert(luminance(color) < @dark, "#{color} is not dark")

      assert String.downcase(source) =~ @cyan
    end
  end

  describe "favicon.ico" do
    test "carries 16, 32 and 48 px PNG entries" do
      assert sizes(ico_entries()) == [16, 32, 48]
    end

    test "is rasterized from the dark favicon" do
      {_size, png} = Enum.find(ico_entries(), &(elem(&1, 0) == 32))
      {r, g, b, a} = pixel(png, 16, 3)

      assert a == 255
      assert luminance({r, g, b}) < @dark, "background pixel #{inspect({r, g, b})} is not dark"
    end
  end

  defp sizes(entries), do: Enum.map(entries, &elem(&1, 0))

  defp ico_entries do
    <<0::little-16, 1::little-16, count::little-16, rest::binary>> =
      ico = File.read!(path("favicon.ico"))

    for i <- 0..(count - 1) do
      <<width::8, _::binary-size(7), size::little-32, offset::little-32>> =
        binary_part(rest, i * 16, 16)

      {if(width == 0, do: 256, else: width), binary_part(ico, offset, size)}
    end
  end

  # Decodes one RGBA pixel from an 8-bit, non-interlaced RGBA PNG.
  defp pixel(<<137, "PNG", 13, 10, 26, 10, chunks::binary>>, x, y) do
    {width, data} = png_chunks(chunks, nil, [])
    stride = width * 4
    raw = :zlib.uncompress(data)

    row =
      Enum.reduce(0..y, :binary.copy(<<0>>, stride), fn row_index, previous ->
        <<filter::8, line::binary-size(^stride)>> =
          binary_part(raw, row_index * (stride + 1), stride + 1)

        unfilter(filter, line, previous)
      end)

    <<_::binary-size(^x * 4), r::8, g::8, b::8, a::8, _::binary>> = row
    {r, g, b, a}
  end

  defp png_chunks(<<len::32, "IHDR", body::binary-size(len), _crc::32, rest::binary>>, _, acc) do
    <<width::32, _height::32, 8, 6, 0, 0, 0>> = body
    png_chunks(rest, width, acc)
  end

  defp png_chunks(
         <<len::32, "IDAT", body::binary-size(len), _crc::32, rest::binary>>,
         width,
         acc
       ),
       do: png_chunks(rest, width, [acc, body])

  defp png_chunks(<<_len::32, "IEND", _::binary>>, width, acc),
    do: {width, IO.iodata_to_binary(acc)}

  defp png_chunks(
         <<len::32, _type::binary-4, _::binary-size(len), _crc::32, rest::binary>>,
         width,
         acc
       ),
       do: png_chunks(rest, width, acc)

  defp unfilter(filter, line, previous) do
    up = previous |> :binary.bin_to_list() |> List.to_tuple()

    line
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.reduce([], fn {byte, i}, out ->
      left = if i >= 4, do: Enum.at(out, 3), else: 0
      upleft = if i >= 4, do: elem(up, i - 4), else: 0
      [rem(byte + predict(filter, left, elem(up, i), upleft), 256) | out]
    end)
    |> Enum.reverse()
    |> :binary.list_to_bin()
  end

  defp predict(0, _a, _b, _c), do: 0
  defp predict(1, a, _b, _c), do: a
  defp predict(2, _a, b, _c), do: b
  defp predict(3, a, b, _c), do: div(a + b, 2)

  defp predict(4, a, b, c) do
    p = a + b - c
    {pa, pb, pc} = {abs(p - a), abs(p - b), abs(p - c)}

    cond do
      pa <= pb and pa <= pc -> a
      pb <= pc -> b
      true -> c
    end
  end
end
