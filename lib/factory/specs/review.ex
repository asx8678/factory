defmodule Factory.Specs.Review do
  @moduledoc """
  Kiro's review of a spec: a score out of 100 and a verdict, a pass / warn / fail
  for each check (acceptance criteria, expected results, …) and what to improve.

  The prompt asks for JSON only; `parse/1` reads it and keeps only what it knows.
  """

  @checks [
    {"requirements", "Clear requirements",
     "each requirement is specific and has one meaning; no vague words like fast, easy or nice"},
    {"acceptance", "Acceptance criteria",
     "every requirement has acceptance criteria (gates) that can be checked, e.g. WHEN … THEN the system SHALL …"},
    {"expected_results", "Expected results",
     "the expected outcome is stated: outputs, states, messages, limits and numbers"},
    {"edge_cases", "Errors and edge cases",
     "invalid input, failures, empty states and limits are covered"},
    {"scope", "Scope", "what is in and out of scope is clear"},
    {"testability", "Testable", "an agent could write tests from it without guessing"},
    {"tasks", "Tasks",
     "tasks are small, ordered and trace back to requirements (warn if there are no tasks yet)"}
  ]

  def checks, do: @checks

  def label(id), do: Enum.find_value(@checks, id, fn {i, label, _} -> i == id && label end)

  @doc "The verdict for a score: strong at 80 and up, needs work from 50, weak below."
  def verdict(score) when score >= 80, do: "strong"
  def verdict(score) when score >= 50, do: "needs_work"
  def verdict(_score), do: "weak"

  def prompt(files) do
    checks = Enum.map_join(@checks, "\n", fn {id, _, what} -> "- #{id}: #{what}" end)

    spec =
      Enum.map_join(files, "\n\n", fn {name, text} ->
        ~s(<file name="#{name}">\n#{text}\n</file>)
      end)

    """
    <spec-review>
    Review this software spec before AI agents build from it. Judge whether it is strong enough \
    to build and verify without guessing. Review only the text below: don't read, write or run anything.

    Checks (use these ids):
    #{checks}

    Reply with only this JSON object and nothing else:
    {"score": <0-100>, "summary": "<one or two sentences>", "checks": [{"id": "<check id>", "status": "pass" | "warn" | "fail", "note": "<one sentence: what is good or missing>"}], "improvements": ["<a concrete change, naming the requirement or section it applies to>"]}

    Score 80 or more only if an agent could build and test it as written. Give at most 6 improvements, most important first.
    </spec-review>

    #{spec}
    """
  end

  @doc "Reads Kiro's reply. Returns `{:ok, review}` or `{:error, reason}`."
  def parse(reply) do
    with json when is_binary(json) <- json_object(reply),
         {:ok, %{"score" => score} = data} when is_number(score) <- JSON.decode(json) do
      score = score |> round() |> max(0) |> min(100)
      known = Enum.map(@checks, &elem(&1, 0))

      checks =
        for %{"id" => id, "status" => status} = c <- List.wrap(data["checks"]),
            id in known,
            status in ~w(pass warn fail),
            do: %{"id" => id, "status" => status, "note" => text(c["note"])}

      {:ok,
       %{
         "score" => score,
         "verdict" => verdict(score),
         "summary" => text(data["summary"]),
         "checks" => Enum.sort_by(checks, &Enum.find_index(known, fn k -> k == &1["id"] end)),
         "improvements" =>
           data["improvements"] |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.take(6)
       }}
    else
      _ -> {:error, "Kiro's reply wasn't a review Factory could read."}
    end
  end

  # The outermost {...} in the reply, which may be wrapped in a ```json fence or prose.
  defp json_object(reply) do
    case Regex.run(~r/\{.*\}/s, reply) do
      [json] -> json
      _ -> nil
    end
  end

  defp text(s) when is_binary(s), do: String.trim(s)
  defp text(_), do: ""
end
