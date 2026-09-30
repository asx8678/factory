defmodule Factory.Verifier do
  @moduledoc """
  Checks a task an agent says it finished, on a different model from the one that
  built it (`Factory.Kiro.verify_model/0`, Claude Haiku unless Settings says
  otherwise). Kiro reads the code and runs the task's `Verify:` checks in the project
  folder: it may run commands, such as the tests, but not edit files. It answers
  whether each check passed, with what it saw, and what to fix when one didn't.

  `Factory.Engine` verifies the tasks a building step marked done, before the run
  goes on, and sends the ones that fail back to that step.
  """
  alias Factory.{Kiro, Spec, Specs}

  @doc """
  The task as the run's spec writes it (`Factory.Spec.blocks/1`): its objective,
  steps and checks. Found by title, else by number; a bare block when the spec
  doesn't have it.
  """
  def spec_task(run, task) do
    blocks =
      case run.spec_id && Specs.get_spec(run.spec_id) do
        %{tasks: text} when is_binary(text) -> text |> Spec.blocks() |> elem(1)
        _ -> []
      end

    Enum.find(blocks, &(&1.title == task.title)) ||
      Enum.find(blocks, &(task.ref != nil and &1.ref == task.ref)) ||
      %{title: task.title, objective: nil, details: [], verify: [], requirements: []}
  end

  @doc """
  Verifies one task in `dir`: `{:ok, %{passed:, checks: [%{check, passed, evidence}],
  fix:}}`, or `{:error, reason}` when Kiro couldn't. `summary` is what the building
  agent said it did.
  """
  def verify(block, summary, dir, opts \\ []) do
    model = Keyword.get_lazy(opts, :model, &Kiro.verify_model/0)

    with {:ok, reply} <-
           Kiro.ask(prompt(block, summary),
             workdir: dir,
             model: model,
             allow: ["read", "search", "execute"],
             reply: :last,
             on_tool: Keyword.get(opts, :on_tool),
             usage: Keyword.get(opts, :usage, %{source: "verify_task"})
           ) do
      parse(reply)
    end
  end

  @doc "What the verifying model is asked about one task."
  def prompt(block, summary) do
    objective = block[:objective] || "Not written: work it out from the title and steps."
    steps = Enum.map_join(block.details, "\n", &"- #{&1}")

    checks =
      case block[:verify] || [] do
        [] ->
          "None were written. Check that the objective holds and the steps were done, and " <>
            "run the project's own test command if it has one that runs quickly."

        checks ->
          Enum.map_join(checks, "\n", &"- #{&1}")
      end

    summary = summary |> to_string() |> String.trim() |> String.slice(0, 4000)

    """
    <task-verification>
    You are verifying one task that a coding agent says it finished, in the project in \
    the current folder. You didn't build it: check it for yourself rather than taking \
    the agent's word. Don't change any files. You may read files and run commands that \
    check things (tests, a build, a linter, a quick script), but nothing that changes \
    the project, its data or anything outside it.

    The task: #{block.title}
    Objective: #{objective}

    The approach it was to follow:
    #{if steps == "", do: "Not written.", else: steps}

    The checks that prove it's done:
    #{checks}

    What the agent said it did:
    #{if summary == "", do: "Nothing.", else: summary}

    Go through every check: run it or look, and note what you saw. Then confirm the \
    objective holds in the code. A check you couldn't run fails, unless the code shows \
    plainly that it holds; say which. Don't fail the task for things its checks and \
    objective don't ask for.

    Reply with only this JSON object and nothing else:
    {"passed": true | false, "checks": [{"check": "<the check>", "passed": true | false, "evidence": "<what you ran or read and what it showed, in one line>"}], "fix": "<if it failed: what to change, specific enough to act on; else empty>"}
    </task-verification>
    """
  end

  @doc "Reads the verifying model's reply: `{:ok, %{passed:, checks:, fix:}}`."
  def parse(reply) do
    with [json] <- Regex.run(~r/\{.*\}/s, reply || ""),
         {:ok, %{} = data} <- JSON.decode(json) do
      checks =
        for c <- List.wrap(data["checks"]), is_map(c), is_binary(c["check"]) do
          %{
            "check" => String.trim(c["check"]),
            "passed" => c["passed"] == true,
            "evidence" => Factory.Text.text(c["evidence"])
          }
        end

      passed =
        case data["passed"] do
          p when is_boolean(p) -> p and Enum.all?(checks, & &1["passed"])
          _ -> checks != [] and Enum.all?(checks, & &1["passed"])
        end

      {:ok, %{passed: passed, checks: checks, fix: Factory.Text.text(data["fix"])}}
    else
      _ -> {:error, "The verifying model's reply wasn't something Factory could read."}
    end
  end
end
