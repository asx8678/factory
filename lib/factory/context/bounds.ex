defmodule Factory.Context.Bounds do
  @moduledoc """
  Byte-bounded text for `Factory.Context`, ported from pi-fabric's compaction
  (`src/compaction/bounds.ts`). Everything here is mechanical: clip by UTF-8 bytes on
  character boundaries, keep a prefix with an explicit "[omitted N UTF-8 bytes]"
  marker, collapse whitespace, and sample a long list as its earliest and latest items
  with a count and entry range for what was left out. Same input, same output.
  """

  @doc "The longest prefix of `text` that fits `max` bytes with `suffix` after it."
  def clip(text, max, suffix \\ "…")
  def clip(_text, max, _suffix) when max <= 0, do: ""
  def clip(text, max, _suffix) when byte_size(text) <= max, do: text

  def clip(text, max, suffix) do
    if byte_size(suffix) >= max, do: "", else: prefix(text, max - byte_size(suffix)) <> suffix
  end

  # Back off while the first byte left out continues a character, so none is split.
  defp prefix(text, bytes) do
    n =
      Enum.find(bytes..0//-1, 0, fn n ->
        n == 0 or n >= byte_size(text) or not continuation?(:binary.at(text, n))
      end)

    binary_part(text, 0, n)
  end

  defp continuation?(byte), do: Bitwise.band(byte, 0xC0) == 0x80

  @doc """
  All of `text` when it fits `max` bytes; else a prefix and a line saying how many
  bytes were left out. Returns `{text, omitted_bytes}`.
  """
  def excerpt(text, max) when byte_size(text) <= max, do: {text, 0}

  def excerpt(text, max) do
    kept = clip(text, max(max - 64, 0), "")
    omitted = byte_size(text) - byte_size(kept)
    {clip("#{kept}\n[omitted #{omitted} UTF-8 bytes]", max, ""), omitted}
  end

  @doc "Whitespace collapsed to single spaces, trimmed."
  def canonical(text), do: text |> String.split() |> Enum.join(" ")

  @doc "Flattened to one line and cut to `max` characters, ending in … when cut."
  def truncate(text, max) do
    flat = canonical(text || "")
    if String.length(flat) > max, do: String.slice(flat, 0, max - 1) <> "…", else: flat
  end

  @doc "The first line with any text on it."
  def first_line(text) do
    (text || "") |> String.split("\n") |> Enum.find("", &(String.trim(&1) != "")) |> String.trim()
  end

  @doc """
  At most `max` items: the earliest half (rounded up) and the latest half. Returns
  `%{values:, omitted:, first:, last:, split:}` where `first`/`last` are the ids of the
  first and last item left out and `split` is where the omission line goes.
  """
  def sample(items, max) do
    early = div(max + 1, 2)
    late = div(max, 2)
    count = length(items)

    if count <= max do
      %{values: items, omitted: 0, first: nil, last: nil, split: min(early, count)}
    else
      left_out = Enum.slice(items, early, count - early - late)

      %{
        values: Enum.take(items, early) ++ Enum.take(items, -late),
        omitted: length(left_out),
        first: hd(left_out).id,
        last: List.last(left_out).id,
        split: early
      }
    end
  end

  @doc "Lines of a sample, with the omission line where the left-out items were."
  def sampled_lines(%{values: values, omitted: omitted} = sample, noun, line_fun) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, i} ->
      gap = if omitted > 0 and i == sample.split, do: [omission(sample, noun)], else: []
      gap ++ List.wrap(line_fun.(value))
    end)
  end

  def omission(%{omitted: count, first: first, last: last}, noun),
    do: "… omitted #{count} #{noun}; source entries #{first || "(start)"} → #{last || "(end)"}"
end
