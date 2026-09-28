defmodule Factory.Context.Render do
  @moduledoc """
  Renders the sections of a compacted conversation within fixed byte limits, ported
  from pi-fabric (`src/compaction/render.ts`).

  Recent dialogue is protected: every exchange stays, shortened only when the block
  is over its ceiling. The other sections are historical: each has a ceiling, and when
  together they don't fit what's left of the 32 KiB total, the space is shared out in
  proportion to what each wants, after keeping every header. Identical sections render
  byte for byte the same.
  """
  alias Factory.Context.Bounds

  @max_bytes 32 * 1024
  @transcript_bytes 5120
  @footer_bytes 1536
  @max_lines 128
  @max_line_bytes 1024

  @sections [
    {:dialogue, "[Recent messages and replies]", 12288},
    {:requests, "[Earlier messages]", 4096},
    {:files, "[Files]", 4608},
    {:outstanding, "[Failures]", 4608},
    {:earlier_turns, "[Earlier turns]", 3072},
    {:status, "[Current status]", 2048}
  ]

  def max_bytes, do: @max_bytes

  @doc """
  The summary text and how many dialogue bytes were cut. `range` is the first and
  last entry summarized, `at` the time of the last one.
  """
  def render(sections, range: {first, last}, at: at) do
    {protected, dialogue_omitted} =
      case sections.dialogue do
        [] -> {[], 0}
        lines -> protected_block("[Recent messages and replies]", lines, 12288)
      end

    history =
      for {key, header, max} <- @sections,
          key != :dialogue,
          sections[key] != [],
          do: {header, sections[key], max}

    history =
      if sections.transcript == [],
        do: history,
        else: history ++ [{"[Transcript]", sections.transcript, @transcript_bytes}]

    footer =
      bounded_block(
        "---",
        [
          "[compacted #{at || "(unknown time)"}; cumulative source entries #{first || "(start)"} → #{last || "(end)"}]",
          "The full conversation is kept in Factory's chat history."
        ],
        @footer_bytes
      )

    protected = List.wrap(protected)
    framing = byte_size(footer) + 2 * (length(protected) + length(history)) + 1
    used = protected |> Enum.map(&byte_size/1) |> Enum.sum()
    blocks = protected ++ bounded_history(history, @max_bytes - framing - used) ++ [footer]
    summary = Enum.join(blocks, "\n\n") <> "\n"

    summary =
      if byte_size(summary) <= @max_bytes,
        do: summary,
        else: Bounds.clip(summary, @max_bytes - 1, "") <> "\n"

    {summary, dialogue_omitted}
  end

  defp sampled(lines, keep) when length(lines) <= keep, do: lines

  defp sampled(lines, keep) do
    early = div(keep + 1, 2)
    late = div(keep, 2)

    Enum.take(lines, early) ++
      ["… omitted #{length(lines) - keep} rendered lines"] ++ Enum.take(lines, -late)
  end

  defp bounded_block(header, lines, max) do
    clipped = Enum.map(lines, &Bounds.clip(&1, @max_line_bytes))
    capped = sampled(clipped, min(length(clipped), @max_lines))

    Enum.find_value(length(capped)..0//-1, Bounds.clip(header, max), fn keep ->
      block = Enum.join([header | sampled(capped, keep)], "\n")
      if byte_size(block) <= max, do: block
    end)
  end

  defp bounded_history(blocks, max) do
    candidates =
      Enum.map(blocks, fn {header, lines, ceiling} ->
        text = bounded_block(header, lines, ceiling)
        bytes = byte_size(text)

        minimum =
          if length(lines) == 1,
            do: bytes,
            else: min(bytes, byte_size(Enum.join([header | sampled(lines, 0)], "\n")))

        %{header: header, lines: lines, text: text, bytes: bytes, minimum: minimum}
      end)

    total = candidates |> Enum.map(& &1.bytes) |> Enum.sum()

    if total <= max do
      Enum.map(candidates, & &1.text)
    else
      # Keep every header and omission line (or a whole one-line block), then share the
      # rest in proportion to what each block wants; what one doesn't use goes to the next.
      minimum = candidates |> Enum.map(& &1.minimum) |> Enum.sum()

      {texts, _} =
        Enum.map_reduce(candidates, {max - minimum, total - minimum}, fn c, {remaining, demand} ->
          wanted = c.bytes - c.minimum
          extra = if demand == 0, do: 0, else: min(wanted, div(remaining * wanted, demand))
          text = bounded_block(c.header, c.lines, c.minimum + extra)
          {text, {remaining - (byte_size(text) - c.minimum), demand - wanted}}
        end)

      texts
    end
  end

  # Every item stays; text is shortened only when the whole block is over its ceiling.
  defp protected_block(header, items, max) do
    text = Enum.join([header | items], "\n\n")

    if byte_size(text) <= max do
      {text, 0}
    else
      remaining = max(max - byte_size(header) - 2 * length(items), 0)
      share = div(remaining, length(items))
      budgets = Enum.map(items, &min(byte_size(&1), share))
      remaining = remaining - Enum.sum(budgets)

      {excerpts, {_, omitted}} =
        items
        |> Enum.zip(budgets)
        |> Enum.map_reduce({remaining, 0}, fn {item, budget}, {remaining, omitted} ->
          extra = min(remaining, byte_size(item) - budget)
          {excerpt, more} = Bounds.excerpt(item, budget + extra)
          {excerpt, {remaining - extra, omitted + more}}
        end)

      {Enum.join([header | excerpts], "\n\n"), omitted}
    end
  end
end
