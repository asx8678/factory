defmodule Factory.Engine.Prompt do
  @moduledoc """
  What an agent step of a run is asked (`Factory.Engine`): the job and the approved
  spec, the data sources attached to the agent, its own prompt, what the cards before
  it handed over, and Factory's rules for the step, fitted to the prompt budget
  (`Factory.Context.fit/2`). Text the run or its agents wrote can be shortened;
  Factory's own lines can't. An agent that searches the web gets it all with what
  identifies anyone taken out (`Factory.Redact`).
  """
  alias Factory.{Sources, Workflows}
  alias Factory.Agents.Agent
  alias Factory.Runs.Run

  # The prompt's parts in order, fitted to the budget. Text the run or its agents wrote
  # (job, spec, hand-offs, sources) can be shortened; Factory's own lines can't.
  @doc "The step's prompt, its parts fitted to the budget (`Factory.Context.fit/2`)."
  def fit(run, steps, step, focus \\ nil) do
    notes = Map.get(step, :notes, %{})
    kind = (workflow = Workflows.for_run(run)) && Workflows.kind(workflow)

    # An agent that searches the web gets everything with what identifies anyone taken
    # out (`Factory.Redact`), whatever the agents before it wrote.
    clean =
      if step.agent && Agent.web?(step.agent) do
        redact = redaction(run)
        &Factory.Redact.text(&1, redact)
      else
        & &1
      end

    # Each arrow in: what the agent before handed over, then what the arrow says.
    handoffs =
      Enum.flat_map(step.after, fn id ->
        from = Enum.find(steps, &(&1.id == id))
        text = clean.(run.progress["outputs"][id])
        note = clean.(notes[id])

        [
          text && tag(~s(<handoff from="#{from.name}">), text, "</handoff>", 64 * 1024),
          note &&
            tag(
              ~s(<handoff-instructions from="#{from.name}">),
              note,
              "</handoff-instructions>",
              8 * 1024
            )
        ]
        |> Enum.filter(& &1)
      end)

    own = String.trim((step.agent && step.agent.prompt) || "")
    feedback = get_in(run.progress, ["feedback", step.id])

    # The brief: who the agent is, the job, the rules, the spec, its sources and
    # instructions. The same for every pass of this step, so a session that has it
    # already isn't sent it again (`Factory.Kiro.Session`).
    brief =
      [
        "You are #{step.name}, one agent in a team that works through a job step by step. " <>
          "Your part: #{blank(step.does, "do what the job needs")}.",
        job(run, step, kind),
        kind == "incident" && clean.(Factory.Runs.Troubleshooting.mode_line(project_dir(run))),
        # Where the attached files are, for the agents that may read them.
        kind == "incident" && !Agent.web?(step.agent || %{}) && Factory.Evidence.describe(run),
        # The commands an agent that only reads may run, so it doesn't spend turns on
        # ones that are refused.
        Agent.read_only?(step) && Factory.Specs.Planner.looking_rule(),
        run |> base_specs() |> List.wrap() |> Enum.map(&clean_part(&1, clean)),
        run.spec && tag("<spec>", clean.(run.spec), "</spec>", 96 * 1024),
        clean_part(sources(step), clean),
        own != "" && %{head: "Your instructions:\n", body: own, tail: "", max: 16 * 1024}
      ]
      |> List.flatten()
      |> Enum.reject(&(&1 in [nil, false, ""]))

    # What this pass is: what's done, what was handed over, feedback, and how to finish.
    ask =
      [
        clean_part(task_status(run), clean),
        handoffs != [] && ["What the agents before you handed over:" | handoffs],
        feedback &&
          [
            "This is another pass: #{feedback["from"]} sent the work back. Fix what they say.",
            tag(
              ~s(<feedback from="#{feedback["from"]}">),
              clean.(feedback["text"]),
              "</feedback>",
              16 * 1024
            )
          ],
        focus && focus_text(focus),
        if(Agent.read_only?(step),
          do: "Don't change any files: read, check and report.",
          else: "Make the changes in the project folder."
        ) <>
          " When you're done, reply with a short summary of what you did and what the next agent needs to know.",
        marks_tasks?(run, step) && complete_rule(focus),
        send_back_rule(steps, step)
      ]
      |> List.flatten()
      |> Enum.reject(&(&1 in [nil, false, ""]))

    fitted = Factory.Context.fit(brief ++ ask)
    {brief_parts, ask_parts} = Enum.split(fitted.parts, length(brief))

    Map.merge(fitted, %{
      brief: Enum.join(brief_parts, "\n\n"),
      ask: Enum.join(ask_parts, "\n\n")
    })
  end

  # The job as the person wrote it. A troubleshooting run's is mostly the errors and
  # logs they pasted, so it gets as much room as a spec. An agent that searches the web
  # isn't shown it (`Agent.web?/1`): what it looks up comes from the hand-overs, where
  # the signatures have nothing that identifies anyone, so it can't send the person's
  # material anywhere, whatever that material says.
  defp job(run, step, kind) do
    if step.agent && Agent.web?(step.agent),
      do:
        "<job>Not shown to agents that search the web. Work from the hand-over and the " <>
          "case file: what to look up is there.</job>",
      else: tag("<job>", run.description || run.title, "</job>", job_room(kind))
  end

  defp clean_part(%{body: body} = part, clean), do: %{part | body: clean.(body)}
  defp clean_part(text, clean) when is_binary(text), do: clean.(text)
  defp clean_part(nil, _clean), do: nil

  # What an agent that searches the web never sees, besides what `Factory.Redact` finds
  # itself: the names listed in Settings, the user names anything in the run shows (the
  # attached files too, learned as they came: `Factory.Chat`), and the run's folders.
  defp redaction(run) do
    texts = [run.description, run.spec] ++ Map.values(run.progress["outputs"] || %{})

    # A run whose files came before Factory learned from them as they came.
    attached =
      (run.settings || %{})["evidence_users"] ||
        Factory.Redact.users_in(Factory.Evidence.heads(run))

    [
      names: Factory.Redact.saved_names(),
      users: Enum.uniq(Factory.Redact.users_in(texts) ++ attached),
      paths: [project_dir(run), Factory.Evidence.root(), Factory.Kiro.config(:workspace)]
    ]
  end

  defp job_room("incident"), do: 96 * 1024
  defp job_room(_kind), do: 16 * 1024

  @doc "The folder the run's agents work in."
  def project_dir(run) do
    case String.trim(run.settings["project_dir"] || "") do
      "" -> nil
      dir -> dir
    end
  end

  # One task to build this turn, as the spec writes it.
  defp focus_text({task, block}) do
    lines = Map.get(block, :lines) || ["#{number(task)}. #{task.title}"]

    tag(
      ~s(<this-task number="#{number(task)}">),
      "Build task #{number(task)} only, this turn: the other tasks are for later turns " <>
        "or other agents. Follow its approach and meet its checks.\n\n" <> Enum.join(lines, "\n"),
      "</this-task>",
      16 * 1024
    )
  end

  defp complete_rule(nil),
    do:
      "As you finish each task in the spec, built and checked, mark it done with the " <>
        "factory tool complete_tasks, giving its number. get_tasks shows which are done."

  defp complete_rule({task, _block}),
    do:
      "When task #{number(task)} is built and its checks pass, mark it done with the " <>
        "factory tool complete_tasks, giving its number."

  # When some tasks are done already (a run run again for tasks added later), which
  # ones: the agents work on the rest.
  defp task_status(%Run{tasks: tasks}) do
    if Enum.any?(tasks, &(&1.status == "done")) and Enum.any?(tasks, &(&1.status != "done")) do
      tag(
        "<task-status>",
        Factory.RunTools.describe(tasks) <>
          "\nWork on the open ones; the done ones are built already.",
        "</task-status>",
        8 * 1024
      )
    end
  end

  # A step with an arrow back decides whether the work goes round again.
  defp send_back_rule(steps, %{loops: [target | _]} = step) do
    to = Enum.find(steps, &(&1.id == target))
    note = step.back_notes[target]

    [
      "Then give your verdict with the factory tool verdict: approved if the work is " <>
        "good, or send_back with what to fix to have #{to.name} do another pass. If you " <>
        "don't have that tool, end your reply with one line instead: `Approved`, or " <>
        "`Send back: <what to fix>`.",
      note &&
        tag(
          ~s(<send-back-instructions to="#{to.name}">),
          note,
          "</send-back-instructions>",
          8 * 1024
        )
    ]
  end

  defp send_back_rule(_steps, _step), do: nil

  defp tag(open, text, close, max),
    do: %{head: open <> "\n", body: String.trim(text), tail: "\n" <> close, max: max}

  # The data sources attached to the agent: the list inside <data-sources> can be shortened.
  defp sources(%{agent: nil}), do: nil

  defp sources(step) do
    case Sources.context_for_agent(step.agent) do
      "" ->
        nil

      text ->
        case Regex.run(~r/\A(<data-sources>\n)(.*)(\n<\/data-sources>)\z/s, text) do
          [_, head, body, tail] -> %{head: head, body: body, tail: tail, max: 32 * 1024}
          nil -> %{head: "", body: text, tail: "", max: 32 * 1024}
        end
    end
  end

  # The base specs the run includes: rules every agent follows.
  defp base_specs(run) do
    case Factory.Specs.base_files_for_run(run) do
      [] ->
        nil

      files ->
        [
          "Rules to follow in everything you do:"
          | Enum.map(files, fn {name, text} ->
              tag(~s(<base-spec name="#{name}">), text, "</base-spec>", 32 * 1024)
            end)
        ]
    end
  end

  @doc "A task's number as the spec gives it, else its place in the list."
  def number(%{ref: ref}) when is_binary(ref), do: ref
  def number(task), do: "#{task.position}"

  @doc """
  Whether the step marks the run's tasks done as it finishes them (`Factory.RunTools`):
  agents that change the project do; ones that only read and check don't.
  """
  def marks_tasks?(run, step), do: run.tasks != [] and not Agent.read_only?(step)

  defp blank(s, default), do: if(String.trim(s || "") == "", do: default, else: s)
end
