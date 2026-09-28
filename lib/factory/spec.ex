defmodule Factory.Spec do
  @moduledoc """
  Reads tasks out of a spec. Understands Kiro's `tasks.md` checklist
  (`- [ ] 1. Title`) and falls back to a plain numbered list (`1. Title`).
  Only top-level lines count; indented sub-items are details of the task above.
  """

  @checkbox ~r/^[-*] \[[ xX]\]\s+(?:(\d+(?:\.\d+)*)\.?\s+)?(.+)$/
  @numbered ~r/^(\d+)[.)]\s+(.+)$/

  @doc "Returns `[%{ref: \"1\" | nil, title: \"...\"}]` in document order."
  def parse_tasks(markdown) do
    lines = String.split(markdown, ~r/\R/u)

    case collect(lines, @checkbox) do
      [] -> collect(lines, @numbered)
      tasks -> tasks
    end
  end

  defp collect(lines, regex) do
    for line <- lines, match = Regex.run(regex, line), [_, ref, title] = match do
      %{
        ref: if(ref == "", do: nil, else: ref),
        title: title |> String.trim() |> String.slice(0, 250)
      }
    end
  end

  @doc "Picks the file tasks come from: `tasks.md` if present, otherwise the first file that has any."
  def tasks_from_files(files) do
    ordered =
      Enum.sort_by(files, fn {name, _} -> String.downcase(Path.basename(name)) != "tasks.md" end)

    Enum.find_value(ordered, {nil, []}, fn {name, content} ->
      case parse_tasks(content) do
        [] -> nil
        tasks -> {name, tasks}
      end
    end)
  end

  @doc """
  Splits a tasks file into its tasks, keeping every line so it can be written back.
  Returns `{preamble_lines, blocks}`; each block is

      %{title:, ref:, done:, details: [line], requirements: [ref], lines: [raw line]}

  where `details` are the task's sub-items (without the bullet) and `requirements`
  come from a `_Requirements: 1.1, 1.2_` line.
  """
  def blocks(markdown) do
    lines = String.split(markdown || "", ~r/\R/u)
    regex = if collect(lines, @checkbox) == [], do: @numbered, else: @checkbox

    {preamble, blocks} =
      Enum.reduce(lines, {[], []}, fn line, {pre, blocks} ->
        cond do
          Regex.match?(regex, line) -> {pre, [[line] | blocks]}
          blocks == [] -> {[line | pre], blocks}
          true -> {pre, [[line | hd(blocks)] | tl(blocks)]}
        end
      end)

    blocks =
      blocks
      |> Enum.reverse()
      |> Enum.map(fn block ->
        block |> Enum.reverse() |> trim_trailing_blank() |> block(regex)
      end)

    {preamble |> Enum.reverse() |> trim_trailing_blank(), blocks}
  end

  defp block([first | rest] = lines, regex) do
    [ref, title] =
      case Regex.run(regex, first) do
        [_, ref, title] -> [ref, title]
      end

    {requirements, details} =
      rest
      |> Enum.map(&(&1 |> String.trim() |> String.replace(~r/^[-*]\s+/, "")))
      |> Enum.reject(&(&1 == ""))
      |> Enum.split_with(&Regex.match?(~r/^_?Requirements?:/i, &1))

    requirements =
      requirements
      |> Enum.flat_map(fn line ->
        line
        |> String.replace(~r/^_?Requirements?:\s*|_$/i, "")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
      end)

    %{
      ref: if(ref == "", do: nil, else: ref),
      title: String.trim(title),
      done: Regex.match?(~r/^[-*] \[[xX]\]/, first),
      details: details,
      requirements: requirements,
      lines: lines
    }
  end

  @doc """
  Rewrites a block with a new title, details and requirements, keeping its
  bullet, checkbox and number. Details are written as sub-items, then the
  requirements as a `_Requirements: …_` line.
  """
  def edit_block(%{lines: [first | _]} = block, title, details, requirements) do
    title = title |> String.replace(~r/\s*\R\s*/u, " ") |> String.trim()

    first =
      case Regex.run(~r/^([-*] \[[ xX]\]\s+(?:\d+(?:\.\d+)*\.?\s+)?|\d+[.)]\s+)/, first) do
        [_, prefix] -> prefix <> title
        nil -> title
      end

    rest =
      Enum.map(details, &"  - #{&1}") ++
        if(requirements == [],
          do: [],
          else: ["  - _Requirements: #{Enum.join(requirements, ", ")}_"]
        )

    lines = [first | rest]
    %{block | title: title, details: details, requirements: requirements, lines: lines}
  end

  defp trim_trailing_blank(lines),
    do: lines |> Enum.reverse() |> Enum.drop_while(&(String.trim(&1) == "")) |> Enum.reverse()

  @doc "Writes tasks back as text, numbering them 1, 2, 3… in the order given."
  def render_blocks(preamble, blocks) do
    tasks =
      blocks
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {%{lines: [first | rest]}, n} ->
        first =
          cond do
            Regex.match?(~r/^[-*] \[[ xX]\]\s+\d+(?:\.\d+)*\.?\s+/, first) ->
              Regex.replace(~r/^([-*] \[[ xX]\]\s+)\d+(?:\.\d+)*\.?\s+/, first, "\\g{1}#{n}. ")

            Regex.match?(~r/^\d+[.)]\s+/, first) ->
              Regex.replace(~r/^\d+([.)])\s+/, first, "#{n}\\g{1} ")

            true ->
              first
          end

        Enum.join([first | rest], "\n")
      end)

    case Enum.join(preamble, "\n") do
      "" -> tasks <> "\n"
      pre -> pre <> "\n\n" <> tasks <> "\n"
    end
  end
end
