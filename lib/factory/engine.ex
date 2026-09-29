defmodule Factory.Engine do
  @moduledoc """
  Carries out a queued run by following its workflow's arrows.

  The steps come from the canvas of the workflow the run uses: a card runs once every
  card with an arrow into it has finished, in reading order where the arrows don't
  decide. Each agent works in the run's project folder on Kiro, with

    * the job and the approved spec (requirements, design, tasks),
    * the data sources attached to it by arrows (`Factory.Sources.context_for_agent/1`),
    * its own prompt, and
    * what the cards with arrows into it handed over.

  The prompt is kept within `Factory.Context.fit/2`'s budget: a part that doesn't fit
  is shortened with an explicit omission marker, and each step's prompt size and hash
  go in the run's progress (`"prompts"`), so what an agent was sent can be checked.

  An action card (`Factory.Actions`) runs when the cards before it are done, with
  `{{summary}}` filled from what they handed over.

  An arrow pointing back to an earlier card (Reviewer → Coder) is a loop: the card it
  starts from ends its reply with "Approved" or "Send back: <what to fix>", and sent
  back, the work goes again from the earlier card with that feedback, up to twice.

  Progress is kept on the run (`progress`), so a paused or failed run resumes at the
  step it stopped at. A failed step pauses the run; `/resume` tries it again.
  """
  require Logger
  alias Factory.{Actions, Agents, Kiro, Runs, Sources, Workflows}
  alias Factory.Agents.Agent
  alias Factory.Runs.Run

  @doc "Runs a queued run in the background. Does nothing when the engine is switched off (tests)."
  def start(%Run{id: id}) do
    if Application.get_env(:factory, :run_engine, true) do
      Task.Supervisor.start_child(Factory.TaskSupervisor, fn -> run(id) end)
    end

    :ok
  end

  @doc "Whether a worker still owns this run, including while its current step finishes."
  def running?(run_id) when is_binary(run_id), do: running?(String.to_integer(run_id))
  def running?(run_id), do: Registry.lookup(Factory.Kiro.Registry, {__MODULE__, run_id}) != []

  @doc """
  The run's steps in the order they run: its workflow's canvas cards,
  `[%{id:, kind:, name:, does:, after: [ids], loops: [ids], notes:, agent:}]`.
  `after` are the steps it waits for; `loops` the earlier steps it can send the work
  back to (an arrow pointing back, see `canvas_steps/1`).
  """
  def steps(%Run{} = run) do
    case Workflows.for_run(run) do
      nil -> []
      workflow -> canvas_steps(workflow.id)
    end
  end

  @doc "Checks that the run's workflow exists and has steps to execute."
  def executable_steps(%Run{} = run) do
    case Workflows.for_run(run) do
      nil ->
        {:error,
         "This run's workflow no longer exists. Choose an existing workflow for a new run."}

      workflow ->
        case canvas_steps(workflow.id) do
          [] ->
            {:error, "The workflow has no steps yet. Add agents under Workflows, then try again."}

          steps ->
            {:ok, steps}
        end
    end
  end

  @doc "A workflow's steps in the order they'd run, as `steps/1` gives them for a run on it."
  def workflow_steps(workflow_id), do: canvas_steps(workflow_id)

  # An arrow that closes a loop (it points to a card that leads to its own start, like
  # Reviewer → Coder) doesn't make the earlier card wait: it's a way to send the work
  # back. The other arrows are hand-offs and decide the order.
  defp canvas_steps(workflow_id) do
    cards = Agents.list_agents(workflow_id) |> Enum.sort_by(&{&1.y, &1.x, &1.id})
    ids = MapSet.new(cards, & &1.id)

    links =
      Workflows.links(workflow_id) |> Enum.filter(&(&1.source_id in ids and &1.target_id in ids))

    back = back_links(cards, links)

    {loops, handoffs} =
      Enum.split_with(links, &MapSet.member?(back, {&1.source_id, &1.target_id}))

    preds = Enum.group_by(handoffs, & &1.target_id, & &1.source_id)
    ordered = topological(cards, preds)
    order = Enum.map(ordered, &"agent-#{&1.id}")

    ordered
    |> Enum.map(fn card ->
      %{
        id: "agent-#{card.id}",
        kind: card.kind,
        name: if(card.kind == "action", do: Actions.label(card), else: card.name),
        does: card.role || "",
        after: Enum.map(Map.get(preds, card.id, []), &"agent-#{&1}"),
        # The earlier steps this one can send the work back to, first in run order first.
        loops:
          for(l <- loops, l.source_id == card.id, do: "agent-#{l.target_id}")
          |> Enum.sort_by(&Enum.find_index(order, fn id -> id == &1 end)),
        # What each arrow into this card says on its hand-off, by the step it comes from,
        # and what an arrow back from this card says about sending the work back.
        notes:
          for(
            l <- handoffs,
            l.target_id == card.id,
            String.trim(l.prompt || "") != "",
            into: %{},
            do: {"agent-#{l.source_id}", l.prompt}
          ),
        back_notes:
          for(
            l <- loops,
            l.source_id == card.id,
            String.trim(l.prompt || "") != "",
            into: %{},
            do: {"agent-#{l.target_id}", l.prompt}
          ),
        agent: card
      }
    end)
  end

  # Arrows that close a loop: depth first from the cards nothing points to, in reading
  # order, an arrow to a card on the current path goes back.
  defp back_links(cards, links) do
    rank = cards |> Enum.with_index() |> Map.new(fn {c, i} -> {c.id, i} end)

    children =
      links
      |> Enum.group_by(& &1.source_id, & &1.target_id)
      |> Map.new(fn {id, targets} -> {id, Enum.sort_by(targets, &rank[&1])} end)

    pointed_to = MapSet.new(links, & &1.target_id)
    starts = Enum.reject(cards, &MapSet.member?(pointed_to, &1.id)) ++ cards

    {back, _seen} =
      Enum.reduce(starts, {MapSet.new(), MapSet.new()}, fn card, acc ->
        visit(card.id, children, MapSet.new(), acc)
      end)

    back
  end

  defp visit(id, children, path, {back, seen}) do
    if MapSet.member?(seen, id) do
      {back, seen}
    else
      path = MapSet.put(path, id)

      Enum.reduce(Map.get(children, id, []), {back, MapSet.put(seen, id)}, fn child,
                                                                              {back, seen} ->
        if MapSet.member?(path, child),
          do: {MapSet.put(back, {id, child}), seen},
          else: visit(child, children, path, {back, seen})
      end)
    end
  end

  # Kahn's algorithm, taking the first ready card in reading order each time. The
  # arrows it follows have no loops (`back_links/2` took those out).
  defp topological(cards, preds), do: topological(cards, preds, MapSet.new(), [])

  defp topological([], _preds, _done, acc), do: Enum.reverse(acc)

  defp topological(cards, preds, done, acc) do
    ready =
      Enum.find(cards, fn c -> Enum.all?(Map.get(preds, c.id, []), &MapSet.member?(done, &1)) end)

    next = ready || hd(cards)
    topological(List.delete(cards, next), preds, MapSet.put(done, next.id), [next | acc])
  end

  @doc "Runs the run's remaining steps, in the calling process."
  def run(run_id) when is_binary(run_id), do: run(String.to_integer(run_id))

  def run(run_id) do
    key = {__MODULE__, run_id}

    case Registry.register(Factory.Kiro.Registry, key, nil) do
      {:ok, _} ->
        try do
          execute(run_id)
        rescue
          # A step that raises (not one that returns an error) must not leave the run
          # "running" with no worker: pause it and say why, like a failed step.
          e ->
            reason = "Factory hit an unexpected error: #{Exception.message(e)}"
            Logger.error("Run #{run_id} crashed: " <> Exception.format(:error, e, __STACKTRACE__))
            crashed(run_id, reason)
        catch
          :exit, why ->
            crashed(run_id, "Factory stopped unexpectedly: #{Exception.format_exit(why)}")
        after
          Registry.unregister(Factory.Kiro.Registry, key)
        end

      {:error, {:already_registered, _}} ->
        {:error, :already_running}
    end
  end

  defp execute(run_id) do
    result =
      Runs.with_locked_run(run_id, fn run ->
        if run.status in ["queued", "running"] do
          with {:ok, steps} <- executable_steps(run) do
            progress = Map.merge(%{"done" => [], "outputs" => %{}}, run.progress || %{})

            {:ok, run} =
              Runs.update_run(run, %{status: "running", progress: Map.delete(progress, "error")})

            {:ok, {run, steps}}
          else
            {:error, reason} ->
              {:ok, run} =
                Runs.update_run(run, %{
                  status: "paused",
                  progress: Map.put(run.progress, "error", reason)
                })

              Runs.post(run, "factory", reason <> " The run is paused.")
              {:ok, {:invalid_workflow, reason}}
          end
        else
          {:ok, run}
        end
      end)

    case result do
      {:ok, {%Run{} = run, steps}} ->
        walk(run, steps, Enum.reject(steps, &(&1.id in run.progress["done"])))

      {:ok, {:invalid_workflow, reason}} ->
        {:error, reason}

      other ->
        other
    end
  end

  defp walk(run, steps, []), do: finish(run, steps)

  defp walk(run, steps, [step | rest]) do
    # Pausing or cancelling takes effect between steps.
    run = Runs.get_run(run.id)

    if run.status == "running" do
      # A verdict from an earlier pass of this step mustn't decide this one.
      progress =
        run.progress
        |> Map.put("current", step.id)
        |> Map.update("verdicts", %{}, &Map.delete(&1, step.id))

      {:ok, run} = Runs.update_run(run, %{progress: progress})

      case do_step(run, steps, step) do
        {:ok, output, sent} ->
          # Read again: the step's tools may have written to the run while it worked.
          run = Runs.get_run(run.id)

          progress =
            run.progress
            |> Map.update!("done", &(&1 ++ [step.id]))
            |> Map.update!("outputs", &Map.put(&1, step.id, output))
            |> then(
              &if sent, do: put_in(&1, [Access.key("prompts", %{}), step.id], sent), else: &1
            )
            |> Map.delete("current")

          {:ok, run} = Runs.update_run(run, %{progress: progress})

          case send_back(run, steps, step, output) do
            {:again, run, again} -> walk(run, steps, again)
            nil -> walk(run, steps, rest)
          end

        {:error, reason} ->
          fail(run, step, reason)
      end
    end
  end

  # A step with an arrow back ends its reply with "Approved" or "Send back: <what to
  # fix>". Sent back, the work goes again from that earlier step, with the feedback,
  # at most @max_rounds times per step; after that the run carries on.
  @max_rounds 2

  defp send_back(run, steps, %{loops: [target | _]} = step, output) do
    rounds = get_in(run.progress, ["rounds", step.id]) || 0
    to = Enum.find(steps, &(&1.id == target))

    # The verdict tool's answer (`Factory.RunTools`), else the reply's last line.
    fix =
      case get_in(run.progress, ["verdicts", step.id]) do
        %{"decision" => "send_back", "fix" => fix} -> fix
        %{"decision" => "approved"} -> nil
        nil -> verdict(output)
      end

    case {fix, rounds < @max_rounds} do
      {nil, _} ->
        nil

      {_fix, false} ->
        Runs.post(
          run,
          "factory",
          "#{step.name} sent it back again, but #{to.name} has had #{@max_rounds} more passes. Carrying on.",
          meta: meta(step)
        )

        nil

      {fix, true} ->
        again = steps |> Enum.drop_while(&(&1.id != target)) |> Enum.map(& &1.id)

        progress =
          run.progress
          |> Map.update!("done", &(&1 -- again))
          |> put_in([Access.key("rounds", %{}), step.id], rounds + 1)
          |> put_in([Access.key("feedback", %{}), target], %{"from" => step.name, "text" => fix})

        {:ok, run} = Runs.update_run(run, %{progress: progress})

        Runs.post(
          run,
          "factory",
          "#{step.name} sent it back to #{to.name} (pass #{rounds + 1} of #{@max_rounds}): #{fix}",
          meta: meta(step)
        )

        {:again, run, Enum.filter(steps, &(&1.id in again))}
    end
  end

  defp send_back(_run, _steps, _step, _output), do: nil

  @doc ~s{"what to fix" when a reply's last line is "Send back: what to fix", else nil.}
  def verdict(output) do
    last =
      output |> String.split("\n") |> Enum.reverse() |> Enum.find("", &(String.trim(&1) != ""))

    case Regex.run(~r/^\W*send back\W*(.*?)\W*$/i, String.trim(last)) do
      [_, ""] -> String.trim(output)
      [_, fix] -> fix
      nil -> nil
    end
  end

  defp do_step(run, _steps, %{kind: "action", agent: card} = step) do
    set_activity(card, "running", "Running for “#{run.title}”")
    ctx = Actions.context(run) |> Map.put("summary", summary(run, step))

    result =
      case Actions.missing(card) do
        [] -> Actions.run(card, ctx)
        missing -> {:error, "#{step.name} isn't set up: #{Enum.join(missing, ", ")} missing."}
      end

    case result do
      {:ok, out} ->
        set_activity(card, "done", nil)
        say(run, step, if(out == "", do: "Done.", else: out))
        {:ok, out, nil}

      {:error, reason} ->
        set_activity(card, "error", reason)
        {:error, reason}
    end
  end

  defp do_step(run, steps, step) do
    set_activity(step.agent, "running", "Working on “#{run.title}”")
    dir = run.settings["project_dir"] || Kiro.config(:workspace)

    Runs.post(run, "factory", "#{step.name} is on it#{handed_by(steps, step)}.", meta: meta(step))
    prompt = fit_prompt(run, steps, step)

    result =
      Kiro.ask(prompt.text,
        workdir: dir,
        model: model(run, step),
        allow: Agent.tools(step),
        mcp_servers: run_tools(run, step),
        usage: %{source: "run_step", run_id: run.id, agent_id: step.agent && step.agent.id}
      )

    case result do
      {:ok, reply} ->
        set_activity(step.agent, "done", nil)
        say(run, step, reply)

        {:ok, reply,
         %{
           "tokens" => prompt.tokens,
           "bytes" => prompt.bytes,
           "sha256" => prompt.sha256,
           "omitted_bytes" => prompt.omitted_bytes
         }}

      {:error, reason} ->
        set_activity(step.agent, "error", reason)
        {:error, reason}
    end
  end

  # Agents that change the project mark the run's tasks done as they finish them
  # (`Factory.RunTools`); ones that only read and check don't.
  # A step with an arrow back also gets the verdict tool.
  defp run_tools(run, step) do
    tasks = marks_tasks?(run, step)
    verdict = Map.get(step, :loops, []) != []

    if tasks or verdict do
      token = Factory.RunTools.grant(run.id, step.id, tasks: tasks, verdict: verdict)
      [Factory.RunTools.mcp_server(token)]
    else
      []
    end
  end

  defp marks_tasks?(run, step), do: run.tasks != [] and not Agent.read_only?(step)

  @doc "What an agent step is asked to do. Public for tests."
  def prompt(run, steps, step), do: fit_prompt(run, steps, step).text

  # The prompt's parts in order, fitted to the budget. Text the run or its agents wrote
  # (job, spec, hand-offs, sources) can be shortened; Factory's own lines can't.
  defp fit_prompt(run, steps, step) do
    notes = Map.get(step, :notes, %{})

    # Each arrow in: what the agent before handed over, then what the arrow says.
    handoffs =
      Enum.flat_map(step.after, fn id ->
        from = Enum.find(steps, &(&1.id == id))
        text = run.progress["outputs"][id]
        note = notes[id]

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

    [
      "You are #{step.name}, one agent in a team that works through a job step by step. " <>
        "Your part: #{blank(step.does, "do what the job needs")}.",
      tag("<job>", run.description || run.title, "</job>", 16 * 1024),
      base_specs(run),
      run.spec && tag("<spec>", run.spec, "</spec>", 96 * 1024),
      handoffs != [] && ["What the agents before you handed over:" | handoffs],
      feedback &&
        [
          "This is another pass: #{feedback["from"]} sent the work back. Fix what they say.",
          tag(
            ~s(<feedback from="#{feedback["from"]}">),
            feedback["text"],
            "</feedback>",
            16 * 1024
          )
        ],
      sources(step),
      own != "" && %{head: "Your instructions:\n", body: own, tail: "", max: 16 * 1024},
      if(Agent.read_only?(step),
        do: "Don't change any files: read, check and report.",
        else: "Make the changes in the project folder."
      ) <>
        " When you're done, reply with a short summary of what you did and what the next agent needs to know.",
      marks_tasks?(run, step) &&
        "As you finish each task in the spec, built and checked, mark it done with the " <>
          "factory tool complete_tasks, giving its number. get_tasks shows which are done.",
      send_back_rule(steps, step)
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, false, ""]))
    |> Factory.Context.fit()
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

  # {{summary}} for an action: what the cards before it handed over, else the latest step's.
  defp summary(run, step) do
    outputs = run.progress["outputs"] || %{}

    texts =
      case Enum.map(step.after, &outputs[&1]) |> Enum.reject(&is_nil/1) do
        [] -> List.wrap(outputs[List.last(run.progress["done"] || [])])
        texts -> texts
      end

    case texts |> Enum.join("\n\n") |> String.trim() do
      "" -> "Factory run “#{run.title}”."
      text -> String.slice(text, 0, 4000)
    end
  end

  # An agent's own Kiro model, else the run's.
  defp model(run, %{agent: %{model: m}}) when is_binary(m) do
    if m in Kiro.models() and m != "auto", do: m, else: model(run, nil)
  end

  defp model(run, _step), do: run.settings["model"] || "auto"

  defp handed_by(_steps, %{after: []}), do: ""

  defp handed_by(steps, step) do
    names = for id <- step.after, s = Enum.find(steps, &(&1.id == id)), do: s.name
    if names == [], do: "", else: ", after #{Enum.join(names, " and ")}"
  end

  defp finish(run, steps) do
    Runs.with_locked_run(run.id, fn run ->
      if run.status == "running" do
        {:ok, run} =
          Runs.update_run(run, %{status: "done", progress: Map.delete(run.progress, "current")})

        Runs.post(
          run,
          "factory",
          "Done: all #{length(steps)} #{if length(steps) == 1, do: "step", else: "steps"} of the workflow ran." <>
            tasks_note(run.tasks)
        )

        {:ok, run}
      else
        {:ok, run}
      end
    end)
  end

  # The worker crashed: pause the run at its current step with the reason.
  defp crashed(run_id, reason) do
    Runs.with_locked_run(run_id, fn run ->
      if run.status == "running" do
        step = %{name: "The run", agent: nil}
        current = Enum.find(steps(run), &(&1.id == run.progress["current"]))
        fail_locked(run, current || step, reason)
      end

      {:ok, run}
    end)

    {:error, reason}
  end

  # Tasks are done when an agent marked them (`Factory.RunTools`), not because the run ended.
  defp tasks_note([]), do: ""

  defp tasks_note(tasks) do
    case {Enum.count(tasks, &(&1.status == "done")), length(tasks)} do
      {1, 1} ->
        " Its task was marked done."

      {all, all} ->
        " All #{all} tasks were marked done."

      {done, all} ->
        " #{done} of #{all} tasks were marked done; check the others before you rely on them."
    end
  end

  defp fail(run, step, reason) do
    Runs.with_locked_run(run.id, fn run ->
      if run.status == "running", do: fail_locked(run, step, reason)
      {:ok, run}
    end)

    {:error, reason}
  end

  defp fail_locked(run, step, reason) do
    progress =
      run.progress
      |> Map.put("error", reason)
      |> then(&if step[:id], do: Map.put(&1, "current", step.id), else: &1)

    {:ok, run} = Runs.update_run(run, %{status: "paused", progress: progress})

    Runs.post(
      run,
      "factory",
      "#{step.name} failed: #{reason}\nThe run is paused at this step. Fix the cause, then /resume to try it again.",
      meta: meta(step)
    )
  end

  defp say(run, step, text),
    do: Runs.post(run, "factory", String.trim(text), author: step.name, meta: meta(step))

  defp meta(%{agent: %{id: id}}), do: %{"agent_id" => id}
  defp meta(_), do: %{}

  defp set_activity(nil, _status, _activity), do: :ok
  defp set_activity(card, status, activity), do: Agents.set_activity(card.id, status, activity)

  @doc "Runs left running when Factory stopped are paused, to resume by hand."
  def reset_runs do
    import Ecto.Query

    Factory.Repo.update_all(from(r in Run, where: r.status == "running"),
      set: [status: "paused"]
    )
  end

  defp blank(s, default), do: if(String.trim(s || "") == "", do: default, else: s)
end
