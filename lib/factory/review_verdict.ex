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

  @line ~r/^[\s>*_#-]*Score:?[\s*_]*(\d{1,3})\s*\/\s*100[\s*_]*[·|:,—–-]*[\s*_]*(Ready to merge|Not ready to merge|Do not merge)[\s*_.]*(?:[—–:-]+\s*(.*))?$/im

  @doc """
  The verdict in a reply, with the reply's text without its line: `{verdict, rest}`, or
  `{nil, body}` when it has none. The decision is the one written; a score without a
  decision line isn't a verdict.
  """
  def split(body) when is_binary(body) do
    case Regex.run(@line, body, return: :index) do
      [{start, len} | _] ->
        [_, score, decision | why] = Regex.run(@line, body)
        score = score |> String.to_integer() |> min(100) |> max(1)

        {key, label} =
          Enum.find(@decisions, fn {_, l} -> String.downcase(l) == String.downcase(decision) end)

        verdict = %{
          score: score,
          decision: key,
          label: label,
          why: why |> List.first("") |> String.trim() |> String.trim("*") |> String.trim()
        }

        rest =
          binary_part(body, 0, start) <>
            binary_part(body, start + len, byte_size(body) - start - len)

        {verdict, String.trim(rest)}

      nil ->
        {nil, body}
    end
  end

  def split(body), do: {nil, body}
end
