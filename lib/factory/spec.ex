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
    lines = String.split(markdown, ~r/\R/)

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
end
