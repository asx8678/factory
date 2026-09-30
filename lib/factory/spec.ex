defmodule Factory.Spec do
  @moduledoc """
  Reads tasks out of a spec. Understands Kiro's `tasks.md` checklist
  (`- [ ] 1. Title`) and falls back to a plain numbered list (`1. Title`).
  Only top-level lines count; indented sub-items are details of the task above.
  """

  @checkbox ~r/^[-*] \[[ xX]\]\s+(?:(\d+(?:\.\d+)*)\.?\s+)?(.+)$/
  @numbered ~r/^(\d+)[.)]\s+(.+)$/

  # A task's labelled sub-items (see `blocks/1`).
  @objective ~r/^\*{0,2}Objective:?\*{0,2}:?\s*/i
  @verify ~r/^\*{0,2}(Verify|Verification):?\*{0,2}:?\s*/i
  @model ~r/^_?\*{0,2}Model:?\*{0,2}:?\s*|_$/i
  @agent ~r/^_?\*{0,2}Agent:?\*{0,2}:?\s*|_$/i

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

      %{title:, ref:, done:, objective:, details: [line], verify: [line], agent:, model:,
        requirements: [ref], lines: [raw line]}

  A task's sub-items say what it is for, how to build it and how to check it:

      - [ ] 2. Add the reset form
        - Objective: A person who forgot their password can ask for a reset link.
        - Add `reset_form/1` to `lib/app_web/live/sign_in_live.ex`.
        - Verify: `mix test test/app_web/live/sign_in_live_test.exs` passes.
        - _Agent: Coder_
        - _Model: auto_
        - _Requirements: 1.1, 1.2_

  `objective` is the `Objective:` line, `verify` the `Verify:` lines, `agent` the
  `_Agent: …_` line (which of the workflow's agents builds it), `model` the `_Model: …_`
  line and `requirements` the `_Requirements: …_` line; every other
  sub-item is a step of the approach, in `details`. Tasks written before these had
  only steps, which read as they always did.
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

    items =
      rest
      |> Enum.map(&(&1 |> String.trim() |> String.replace(~r/^[-*]\s+/, "")))
      |> Enum.reject(&(&1 == ""))
      |> Enum.group_by(&part/1)

    requirements =
      Enum.flat_map(Map.get(items, :requirements, []), fn line ->
        line
        |> String.replace(~r/^_?Requirements?:\s*|_$/i, "")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
      end)

    objective =
      case Enum.map(Map.get(items, :objective, []), &value(&1, @objective)) do
        [] -> nil
        lines -> Enum.join(lines, " ")
      end

    model =
      case Map.get(items, :model, []) do
        [line | _] -> value(line, @model)
        [] -> nil
      end

    agent =
      case Map.get(items, :agent, []) do
        [line | _] -> value(line, @agent)
        [] -> nil
      end

    %{
      ref: if(ref == "", do: nil, else: ref),
      title: String.trim(title),
      done: Regex.match?(~r/^[-*] \[[xX]\]/, first),
      objective: objective,
      details: Map.get(items, :details, []),
      verify: Enum.map(Map.get(items, :verify, []), &value(&1, @verify)),
      agent: agent,
      model: model,
      requirements: requirements,
      lines: lines
    }
  end

  # Which part of a task a sub-item is.
  defp part(line) do
    cond do
      Regex.match?(~r/^_?Requirements?:/i, line) -> :requirements
      Regex.match?(@objective, line) -> :objective
      Regex.match?(@verify, line) -> :verify
      Regex.match?(~r/^_?\*{0,2}Model:/i, line) -> :model
      Regex.match?(~r/^_?\*{0,2}Agent:/i, line) -> :agent
      true -> :details
    end
  end

  defp value(line, label), do: line |> String.replace(label, "") |> String.trim()

  @doc """
  Rewrites a block with a new title, steps (details) and requirements, keeping its
  bullet, checkbox and number, and its objective, checks and model.
  """
  def edit_block(block, title, details, requirements),
    do: edit_block(block, %{title: title, details: details, requirements: requirements})

  @doc """
  Rewrites a block with the fields in `changes` (`:title`, `:objective`, `:details`,
  `:verify`, `:agent`, `:model`, `:requirements`); the others stay as they are. Written
  in the order `blocks/1` reads them: objective, steps, checks, agent, model,
  requirements.
  """
  def edit_block(%{lines: [first | _]} = block, %{} = changes) do
    block =
      Map.merge(
        %{objective: nil, verify: [], agent: nil, model: nil},
        block
      )

    fields =
      Map.merge(
        block,
        Map.take(changes, ~w(title objective details verify agent model requirements)a)
      )

    title = fields.title |> String.replace(~r/\s*\R\s*/u, " ") |> String.trim()
    objective = blank_nil(fields.objective)
    model = blank_nil(fields.model)
    agent = blank_nil(fields.agent)

    first =
      case Regex.run(~r/^([-*] \[[ xX]\]\s+(?:\d+(?:\.\d+)*\.?\s+)?|\d+[.)]\s+)/, first) do
        [_, prefix] -> prefix <> title
        nil -> title
      end

    rest =
      List.wrap(objective && "  - Objective: #{objective}") ++
        Enum.map(fields.details, &"  - #{&1}") ++
        Enum.map(fields.verify, &"  - Verify: #{&1}") ++
        List.wrap(agent && "  - _Agent: #{agent}_") ++
        List.wrap(model && "  - _Model: #{model}_") ++
        if(fields.requirements == [],
          do: [],
          else: ["  - _Requirements: #{Enum.join(fields.requirements, ", ")}_"]
        )

    %{
      block
      | title: title,
        objective: objective,
        details: fields.details,
        verify: fields.verify,
        agent: agent,
        model: model,
        requirements: fields.requirements,
        lines: [first | rest]
    }
  end

  defp blank_nil(nil), do: nil

  defp blank_nil(text) do
    case text |> to_string() |> String.replace(~r/\s*\R\s*/u, " ") |> String.trim() do
      "" -> nil
      text -> text
    end
  end

  @doc """
  `title` unless a task in `taken` (titles) already has it, else the title with a
  count, "Title (2)", "Title (3)"…, so no two tasks share one: a run's tasks, their
  statuses and the queue are found by title.
  """
  def unique_title(title, taken) do
    if title in taken do
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(fn n ->
        candidate = "#{title} (#{n})"
        if candidate not in taken, do: candidate
      end)
    else
      title
    end
  end

  @doc """
  The blocks with duplicate titles renamed (`unique_title/2`), earlier ones keeping
  theirs; `taken` are titles already in use (tasks the blocks are added to).
  """
  def unique_titles(blocks, taken \\ []),
    do: rename_duplicates(blocks, taken, & &1.title, &edit_block(&1, %{title: &2}))

  @doc """
  `unique_titles/2` for any shape: `title` reads an item's title and `rename` gives it a
  new one (`Factory.Specs.Planner.unique_titles/2` uses it for its string-keyed tasks).
  """
  def rename_duplicates(items, taken, title, rename) do
    items
    |> Enum.reduce({[], taken}, fn item, {done, taken} ->
      was = title.(item)
      now = unique_title(was, taken)
      item = if now == was, do: item, else: rename.(item, now)
      {[item | done], [now | taken]}
    end)
    |> elem(0)
    |> Enum.reverse()
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
