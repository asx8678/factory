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
  `{{summary}}` filled from what they handed over. One with no arrows at all, in a
  workflow with agents, isn't in the flow yet and doesn't run.

  Each agent step runs on the agent's own Kiro session (`Factory.Kiro.run_step/4`), so
  a step that comes round again carries on the same conversation. Steps that change
  the project mark the run's tasks done with Factory's run tools (`Factory.RunTools`).

  An arrow pointing back to an earlier card (Reviewer → Coder) is a loop: the card it
  starts from gives a verdict with the verdict tool (or ends its reply with "Approved"
  or "Send back: <what to fix>"), and sent back, the work goes again from the earlier
  card with that feedback, up to `max_rounds/0` times.

  A planner card whose run already has its tasks (planned in the chat or on the Spec
  page) passes them on without asking Kiro to plan again.

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
    all = Agents.list_agents(workflow_id)
    all_ids = MapSet.new(all, & &1.id)

    links =
      Workflows.links(workflow_id)
      |> Enum.filter(&(&1.source_id in all_ids and &1.target_id in all_ids))

    cards =
      all |> Enum.reject(&loose_action?(&1, all, links)) |> Enum.sort_by(&{&1.y, &1.x, &1.id})

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

  # An action card with no arrow at all, in a workflow with agents, hasn't been put in
  # the flow yet (the palette drops it unconnected): it doesn't run. Otherwise a
  # "Commit & push" left on the canvas would push. A workflow of only actions runs them.
  defp loose_action?(%{kind: "action", id: id}, all, links) do
    Enum.any?(all, &(&1.kind != "action")) and
      not Enum.any?(links, &(&1.source_id == id or &1.target_id == id))
  end

  defp loose_action?(_card, _all, _links), do: false

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

          # The tasks it finished are checked on another model before the run goes on;
          # ones that fail go back to this step.
          case verify_tasks(run, step, output) do
            {:again, run} ->
              walk(run, steps, [step | rest])

            {:ok, run} ->
              # Paused or cancelled while it verified: nothing more is written.
              run = Runs.get_run(run.id)

              if run.status == "running" do
                case send_back(run, steps, step, output) do
                  {:again, run, again} -> walk(run, steps, again)
                  nil -> walk(run, steps, rest)
                end
              end

            :stopped ->
              nil
          end

        {:error, reason} ->
          fail(run, step, reason)

        # Paused or cancelled between its tasks: the step stays undone, to go on from
        # its open tasks when the run resumes.
        :stopped ->
          nil
      end
    end
  end

  # A step with an arrow back gives a verdict (the verdict tool, else its reply's last
  # line: "Approved" or "Send back: <what to fix>"). Sent back, the work goes again
  # from that earlier step, with the feedback, at most `max_rounds/0` times per step;
  # after that the run carries on.

  @doc "How many more passes a step may ask for: `config :factory, :max_loop_rounds` (default 2)."
  def max_rounds, do: Application.get_env(:factory, :max_loop_rounds, 2)

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

    max_rounds = max_rounds()

    case {fix, rounds < max_rounds} do
      {nil, _} ->
        nil

      {_fix, false} ->
        Runs.post(
          run,
          "factory",
          "#{step.name} sent it back again, but #{to.name} has had #{max_rounds} more passes. Carrying on.",
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
          "#{step.name} sent it back to #{to.name} (pass #{rounds + 1} of #{max_rounds}): #{fix}",
          meta: meta(step)
        )

        {:again, run, Enum.filter(steps, &(&1.id in again))}
    end
  end

  defp send_back(_run, _steps, _step, _output), do: nil

  # Verification: after a step that builds, each task it marked done is checked on a
  # different model (`Factory.Verifier`), which reads the code and runs the task's
  # checks. The results are kept in `progress["verification"]` by task id and told in
  # the chat. Tasks that fail are opened again and the step goes again with what to
  # fix, at most `max_rounds/0` times; after that they stay open and the run carries
  # on. A task the verifier couldn't check (Kiro failed) stays done, and the chat says
  # so. `config :factory, :verify_tasks, false` switches it off. Pausing or cancelling
  # the run stops the verifying between tasks (`:stopped`), and nothing is written then.

  defp verify_tasks(run, step, output) do
    results = run.progress["verification"] || %{}

    todo =
      if Application.get_env(:factory, :verify_tasks, true) and step.kind != "action" and
           marks_tasks?(run, step),
         do:
           Enum.filter(
             run.tasks,
             &(&1.status == "done" and get_in(results, ["#{&1.id}", "passed"]) != true)
           ),
         else: []

    if todo == [], do: {:ok, run}, else: verify_each(run, step, output, todo)
  end

  defp verify_each(run, step, output, todo) do
    model = Kiro.verify_model()
    dir = run.settings["project_dir"] || Kiro.config(:workspace)
    name = Kiro.model_name(model)
    count = if length(todo) == 1, do: "the task", else: "#{length(todo)} tasks"

    set_activity(step.agent, "running", "Verifying “#{run.title}”")

    Runs.post(run, "factory", "Verifying #{count} #{step.name} finished, with #{name}.",
      meta: meta(step)
    )

    checked =
      Enum.reduce_while(todo, [], fn task, checked ->
        # Pausing or cancelling takes effect between tasks.
        if Runs.get_run(run.id).status != "running" do
          {:halt, :stopped}
        else
          block = Factory.Verifier.spec_task(run, task)

          result =
            Factory.Verifier.verify(block, output, dir,
              model: model,
              usage: %{
                source: "verify_task",
                run_id: run.id,
                agent_id: step.agent && step.agent.id
              }
            )

          {:cont, [{task, result} | checked]}
        end
      end)

    run = Runs.get_run(run.id)

    cond do
      checked == :stopped or run.status != "running" ->
        # The tasks stay done; they're checked again when the run resumes.
        set_activity(step.agent, "idle", nil)
        :stopped

      true ->
        checked = Enum.reverse(checked)
        set_activity(step.agent, "done", nil)

        record =
          Map.new(checked, fn {task, result} -> {"#{task.id}", verification(result, model)} end)

        progress = Map.update(run.progress, "verification", record, &Map.merge(&1, record))
        {:ok, run} = Runs.update_run(run, %{progress: progress})

        for {task, result} <- checked, do: say_verified(run, step, task, result, name)

        case for({task, {:ok, %{passed: false} = r}} <- checked, do: {task, r}) do
          [] -> {:ok, run}
          failed -> verify_failed(run, step, failed)
        end
    end
  end

  defp verification({:ok, r}, model),
    do: %{"passed" => r.passed, "checks" => r.checks, "fix" => r.fix, "model" => model}

  defp verification({:error, reason}, model),
    do: %{"passed" => nil, "error" => reason, "model" => model}

  defp say_verified(run, step, task, {:ok, r}, name) do
    passed = Enum.count(r.checks, & &1["passed"])

    head =
      if r.passed,
        do:
          "Task #{number(task)} verified by #{name}: #{passed} of #{length(r.checks)} checks passed.",
        else: "Task #{number(task)} failed verification by #{name}: #{r.fix}"

    lines =
      for c <- r.checks do
        "- #{if c["passed"], do: "✓", else: "✗"} #{c["check"]}" <>
          if(c["evidence"] != "", do: " — #{c["evidence"]}", else: "")
      end

    Runs.post(run, "factory", Enum.join([head | lines], "\n"), meta: meta(step))
  end

  defp say_verified(run, step, task, {:error, reason}, name) do
    Runs.post(
      run,
      "factory",
      "#{name} couldn't verify task #{number(task)}, so it stays done unchecked: #{reason}",
      meta: meta(step)
    )
  end

  defp verify_failed(run, step, failed) do
    rounds = get_in(run.progress, ["verify_rounds", step.id]) || 0
    max_rounds = max_rounds()
    run = Runs.reopen_tasks(run, Enum.map(failed, fn {task, _} -> task.id end))
    Runs.tasks_changed(run)
    which = Enum.map_join(failed, ", ", fn {task, _} -> number(task) end)

    if rounds < max_rounds do
      fix =
        Enum.map_join(failed, "\n\n", fn {task, r} ->
          misses =
            for c <- r.checks, !c["passed"] do
              "- #{c["check"]}" <> if(c["evidence"] != "", do: ": #{c["evidence"]}", else: "")
            end

          Enum.join(
            ["Task #{number(task)}, #{task.title}: #{r.fix}" | misses],
            "\n"
          )
        end)

      progress =
        run.progress
        |> Map.update!("done", &(&1 -- [step.id]))
        |> put_in([Access.key("verify_rounds", %{}), step.id], rounds + 1)
        |> put_in([Access.key("feedback", %{}), step.id], %{
          "from" => "Verification",
          "text" =>
            fix <>
              "\n\nFix these, check them yourself, and mark the tasks done again with complete_tasks."
        })

      {:ok, run} = Runs.update_run(run, %{progress: progress})

      Runs.post(
        run,
        "factory",
        "Task #{which} went back to #{step.name} to fix (pass #{rounds + 1} of #{max_rounds}).",
        meta: meta(step)
      )

      {:again, run}
    else
      Runs.post(
        run,
        "factory",
        "Task #{which} still fails its checks after #{max_rounds} more passes, so it's left open. Carrying on.",
        meta: meta(step)
      )

      {:ok, run}
    end
  end

  # A task's number as the spec gives it, else its place in the list.
  defp number(%{ref: ref}) when is_binary(ref), do: ref
  defp number(task), do: "#{task.position}"

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

  # A planner step when the run's tasks are already planned (in the chat, or on the
  # Spec page): the plan goes straight on, without a second planning turn on Kiro.
  # The agents after it get the spec, approach and tasks, in their prompts.
  defp do_step(%Run{tasks: [_ | _]} = run, steps, %{kind: "planner"} = step) do
    next = for s <- steps, step.id in s.after, do: s.name
    to = if next == [], do: "", else: " to #{Enum.join(next, " and ")}"

    out =
      "The #{length(run.tasks)} tasks were planned before the run started. " <>
        "Follow them in order, as the spec gives them."

    Runs.post(
      run,
      "factory",
      "#{step.name}: the tasks were already planned, so it hands them straight#{to}.",
      meta: meta(step)
    )

    set_activity(step.agent, "done", nil)
    {:ok, out, nil}
  end

  # An agent that builds, with open tasks the plan gives it: one task at a time, each on
  # the model the plan names for it. Otherwise (no plan, nothing left for it, a pass
  # sent back once everything is built) the whole step in one pass.
  defp do_step(run, steps, step) do
    case marks_tasks?(run, step) && own_tasks(run, steps, step) do
      [_ | _] = tasks -> build_each(run, steps, step, tasks)
      _ -> one_pass(run, steps, step)
    end
  end

  defp one_pass(run, steps, step) do
    set_activity(step.agent, "running", "Working on “#{run.title}”")
    Runs.post(run, "factory", "#{step.name} is on it#{handed_by(steps, step)}.", meta: meta(step))
    prompt = fit_prompt(run, steps, step)

    # On the agent's own Kiro session, which posts the reply to the chat and keeps the
    # conversation for a later pass. The prompt carries its sources and instructions.
    activity = "Working on “#{run.title}”"
    opts = step_opts(run, step, prompt, model(run, step), activity, marks_tasks?(run, step))
    result = Kiro.run_step(step.agent, run.id, prompt.ask, opts)

    case result do
      {:ok, reply} ->
        set_activity(step.agent, "done", nil)
        {:ok, reply, sent(prompt)}

      {:error, reason} ->
        set_activity(step.agent, "error", reason)
        {:error, reason}
    end
  end

  # Task by task: each on the agent's own session, so it keeps what it did before, on the
  # model the plan names for the task (else the agent's). A task that isn't marked done
  # is left for verification to catch; the run goes on to the next.
  defp build_each(run, steps, step, tasks) do
    count = length(tasks)
    names = Enum.map_join(tasks, ", ", fn {task, _} -> number(task) end)

    Runs.post(
      run,
      "factory",
      "#{step.name} is on it#{handed_by(steps, step)}: #{if count == 1, do: "task #{names}", else: "tasks #{names}, one at a time"}.",
      meta: meta(step)
    )

    result =
      tasks
      |> Enum.with_index(1)
      |> Enum.reduce_while({[], nil}, fn {{task, block}, n}, {outs, _sent} ->
        run = Runs.get_run(run.id)

        if run.status != "running" do
          {:halt, :stopped}
        else
          model = task_model(run, step, block)

          activity =
            if count == 1,
              do: "Building task #{number(task)} of “#{run.title}”",
              else: "Building task #{number(task)} (#{n} of #{count}) of “#{run.title}”"

          set_activity(step.agent, "running", activity)
          prompt = fit_prompt(run, steps, step, {task, block})

          case Kiro.run_step(
                 step.agent,
                 run.id,
                 prompt.ask,
                 step_opts(run, step, prompt, model, activity, true)
               ) do
            {:ok, reply} -> {:cont, {[reply | outs], sent(prompt)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end
      end)

    case result do
      :stopped ->
        set_activity(step.agent, "idle", nil)
        :stopped

      {:error, reason} ->
        set_activity(step.agent, "error", reason)
        {:error, reason}

      {outs, sent} ->
        set_activity(step.agent, "done", nil)
        {:ok, outs |> Enum.reverse() |> Enum.join("\n\n"), sent}
    end
  end

  # The open tasks this agent builds: the ones the plan gives it by name, and, when it's
  # the first agent that builds, the ones it gives to nobody or to an agent this
  # workflow doesn't have. With the task as the spec writes it (`Factory.Verifier`).
  defp own_tasks(run, steps, step) do
    builders =
      for s <- steps, s.kind != "action", s.agent != nil, not Agent.read_only?(s.agent), do: s

    names = MapSet.new(builders, &String.downcase(&1.name))
    first? = match?([%{id: id} | _] when id == step.id, builders)
    me = String.downcase(step.name)

    for task <- Enum.sort_by(run.tasks, & &1.position),
        task.status != "done",
        block = Factory.Verifier.spec_task(run, task),
        owner = block[:agent] && String.downcase(block.agent),
        owner == me or (first? and (owner == nil or not MapSet.member?(names, owner))),
        do: {task, block}
  end

  # The model for one task: a coding agent's own (Auto unless set on its card), for now;
  # for the others, the plan's when Factory may pick it (`Kiro.task_models/0`, never
  # Sonnet), else the agent's.
  defp task_model(run, %{kind: "coder"} = step, _block), do: model(run, step)

  defp task_model(run, step, block) do
    m = block[:model]

    if is_binary(m) and m != "auto" and m in Kiro.task_models(),
      do: m,
      else: model(run, step)
  end

  # A run step's options for `Factory.Kiro.run_step/4`: the brief (the same for every
  # pass of this step, so the session isn't sent it twice), the model, and the step
  # Factory's run tools act on. `tasks?` is whether this step marks tasks done.
  defp step_opts(run, step, prompt, model, activity, tasks?) do
    [
      brief: {prompt.brief, "#{run.id}:" <> Factory.Context.sha256(prompt.brief)},
      source: "run_step",
      model: model,
      context: false,
      activity: activity,
      step: %{id: step.id, tasks: tasks?, verdict: Map.get(step, :loops, []) != []}
    ]
  end

  # What was sent, for the run's progress (`"prompts"`).
  defp sent(prompt) do
    %{
      "tokens" => prompt.tokens,
      "bytes" => prompt.bytes,
      "sha256" => prompt.sha256,
      "omitted_bytes" => prompt.omitted_bytes
    }
  end

  # Agents that change the project mark the run's tasks done as they finish them
  # (`Factory.RunTools`); ones that only read and check don't. A step with an arrow
  # back also has the verdict tool.
  defp marks_tasks?(run, step), do: run.tasks != [] and not Agent.read_only?(step)

  @doc "What an agent step is asked to do. Public for tests."
  def prompt(run, steps, step), do: fit_prompt(run, steps, step).text

  # The prompt's parts in order, fitted to the budget. Text the run or its agents wrote
  # (job, spec, hand-offs, sources) can be shortened; Factory's own lines can't.
  defp fit_prompt(run, steps, step, focus \\ nil) do
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

    # The brief: who the agent is, the job, the rules, the spec, its sources and
    # instructions. The same for every pass of this step, so a session that has it
    # already isn't sent it again (`Factory.Kiro.Session`).
    brief =
      [
        "You are #{step.name}, one agent in a team that works through a job step by step. " <>
          "Your part: #{blank(step.does, "do what the job needs")}.",
        tag("<job>", run.description || run.title, "</job>", 16 * 1024),
        base_specs(run),
        run.spec && tag("<spec>", run.spec, "</spec>", 96 * 1024),
        sources(step),
        own != "" && %{head: "Your instructions:\n", body: own, tail: "", max: 16 * 1024}
      ]
      |> List.flatten()
      |> Enum.reject(&(&1 in [nil, false, ""]))

    # What this pass is: what's done, what was handed over, feedback, and how to finish.
    ask =
      [
        task_status(run),
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
            tasks_note(run.tasks) <> verified_note(run)
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

  # How many of the done tasks passed verification (Factory.Verifier).
  defp verified_note(run) do
    results = run.progress["verification"] || %{}
    done = Enum.filter(run.tasks, &(&1.status == "done"))
    passed = Enum.count(done, &(get_in(results, ["#{&1.id}", "passed"]) == true))

    cond do
      done == [] or results == %{} -> ""
      passed == length(done) -> " Every one passed verification."
      true -> " #{passed} of #{length(done)} passed verification."
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
