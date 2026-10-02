defmodule Factory.ReviewVerdict do
  @moduledoc """
  A pull request review's verdict, as the Reviewer writes it on a line of its own
  (`Factory.Runs.Types`): `Score: 82/100 · Ready to merge — why`. The score is from 1 to
  100; the decision is Ready to merge, Not ready to merge or Do not merge.
  """

  @decisions [
    {"ready", "Ready to merge"},
    {"not_ready", "Not ready to merge"},
    {"do_not", "Do not merge"}
  ]

  # By characters, not bytes (`u`): read byte by byte, the dashes would take the first
  # bytes of a character after them (`→`, `✅`) and leave the rest as invalid text.
  @line ~r/^[\h*_#-]*Score:?[\h*_]*(\d{1,3})\h*\/\h*100[\h*_]*[·|:,—–-]*[\h*_]*(Ready to merge|Not ready to merge|Do not merge)[\h*_.]*(?:[—–:→|·-]+\h*(.*))?$/iu

  @doc """
  The verdict in a reply, with the reply's text without its line: `{verdict, rest}`, or
  `{nil, body}` when it has none. The decision is the one written; a score without a
  decision line isn't a verdict.

  Only the reply's first line counts, as the Reviewer is told to write it: a line
  further down may be quoted from the pull request, and a card shouldn't say "Ready to
  merge" because the pull request did.
  """
  def split(body) when is_binary(body) do
    with true <- String.valid?(body),
         {first, rest} = first_line(body),
         [_, score, decision | why] <- Regex.run(@line, first) do
      score = score |> String.to_integer() |> min(100) |> max(1)

      {key, label} =
        Enum.find(@decisions, fn {_, l} -> String.downcase(l) == String.downcase(decision) end)

      verdict = %{
        score: score,
        decision: key,
        label: label,
        why: why |> List.first("") |> String.trim() |> String.trim("*") |> String.trim()
      }

      {verdict, String.trim(rest)}
    else
      _ -> {nil, body}
    end
  end

  def split(body), do: {nil, body}

  # The first line with something on it, and what comes after it. By characters too:
  # byte by byte, `\R` takes the last byte of `✅` for a line break.
  defp first_line(body) do
    case String.split(String.trim_leading(body), ~r/\R/u, parts: 2) do
      [line, rest] -> {line, rest}
      [line] -> {line, ""}
    end
  end
end
