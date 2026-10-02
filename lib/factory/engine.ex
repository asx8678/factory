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
  alias Factory.{Actions, Agents, Kiro, Runs, Workflows}
  alias Factory.Agents.Agent
  alias Factory.Engine.{Credits, Prompt}
  alias Factory.Runs.Run

  @doc "Runs a queued run in the background. Does nothing when the engine is switched off (tests)."
  def start(%Run{id: id}) do
    if Application.get_env(:factory, :run_engine, true) do
      case Task.Supervisor.start_child(Factory.TaskSupervisor, fn -> run(id) end) do
        {:ok, _pid} -> :ok
        # Left queued, /resume would refuse it: it's paused, to be resumed.
        {:error, reason} -> fail_to_start(id, reason)
      end
    end

    :ok
  end

  defp fail_to_start(id, reason) do
    Runs.with_locked_run(id, fn run ->
      if run.status == "queued" do
        {:ok, run} =
          Runs.update_run(run, %{
            status: "paused",
            progress: Map.put(run.progress || %{}, "error", "couldn't start")
          })

        Runs.post(
          run,
          "factory",
          "The run couldn't start (#{inspect(reason)}). Type /resume to try again."
        )
      end

      {:ok, run}
    end)
  end

  @doc "Whether a worker still owns this run, including while its current step finishes."
  def running?(run_id) when is_binary(run_id), do: running?(String.to_integer(run_id))
  def running?(run_id), do: Registry.lookup(Factory.Kiro.Registry, {__MODULE__, run_id}) != []

  @doc """
  The run's steps in the order they run: its workflow's canvas cards,
  `[%{id:, kind:, name:, does:, after: [ids], loops: [ids], notes:, agent:}]`.
  `after` are the steps it waits for; `loops` the earlier steps it can send the work
  back to (an arrow pointing back, see `Factory.Engine.Graph`).
  """
  def steps(%Run{} = run) do
    case Workflows.for_run(run) do
      nil -> []
      workflow -> Factory.Engine.Graph.steps(workflow.id)
    end
  end

  @doc "Checks that the run's workflow exists and has steps to execute."
  def executable_steps(%Run{} = run) do
    case Workflows.for_run(run) do
      nil ->
        {:error,
         "This run's workflow no longer exists. Choose an existing workflow for a new run."}

      workflow ->
        case Factory.Engine.Graph.steps(workflow.id) do
          [] ->
            {:error, "The workflow has no steps yet. Add agents under Workflows, then try again."}

          steps ->
            {:ok, steps}
        end
    end
  end

  @doc "A workflow's steps in the order they'd run, as `steps/1` gives them for a run on it."
  def workflow_steps(workflow_id), do: Factory.Engine.Graph.steps(workflow_id)

  @doc "Runs the run's remaining steps, in the calling process."
  def run(run_id) when is_binary(run_id), do: run(String.to_integer(run_id))

  def run(run_id) do
    key = {__MODULE__, run_id}
    # Everything this worker logs says which run it was.
    Logger.metadata(run_id: run_id)

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
            progress =
              %{"done" => [], "outputs" => %{}}
              |> Map.merge(run.progress || %{})
              |> Credits.from_now(run)
              |> Credits.allow_more(run)

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
        resume(run, steps, Enum.reject(steps, &(&1.id in run.progress["done"])))

      {:ok, {:invalid_workflow, reason}} ->
        {:error, reason}

      other ->
        other
    end
  end

  # A run paused while it checked a step's tasks finishes those checks first, even when
  # that step was the last to build: the tasks it hadn't checked don't stay unchecked.
  defp resume(run, steps, rest) do
    case run.progress["verifying"] && Enum.find(steps, &(&1.id == run.progress["verifying"])) do
      nil ->
        walk(run, steps, rest)

      step ->
        case verify_tasks(run, step, run.progress["outputs"][step.id] || "") do
          {:again, run} -> walk(run, steps, [step | rest])
          {:ok, run} -> walk(run, steps, rest)
          :stopped -> nil
        end
    end
  end

  defp walk(run, steps, []), do: finish(run, steps)

  defp walk(run, steps, [step | rest]) do
    # Pausing or cancelling takes effect between steps.
    run = Runs.get_run(run.id)

    cond do
      run.status != "running" ->
        nil

      why = skip_reason(run, step) ->
        skip(run, steps, step, rest, why)

      spent = step.kind != "action" && Credits.over(run) ->
        Credits.pause(run, step, spent)

      true ->
        run_step(run, steps, step, rest)
    end
  end

  @doc "How many credits a run may use before it pauses (`Credits.limit/0`)."
  defdelegate credit_limit, to: Factory.Engine.Credits, as: :limit

  @doc "How many credits the run may use before it pauses next (`Credits.allowance/1`)."
  defdelegate credit_allowance(run), to: Factory.Engine.Credits, as: :allowance

  # In troubleshooting, a step with nothing to do is skipped rather than run only to say
  # so: the Code Investigator with no repository, and the Evidence Analyst in a quick
  # check of an error with nothing attached. They're found by name, as the workflow
  # comes (`Factory.Runs.Types`).
  defp skip_reason(run, %{agent: %{}} = step) do
    if incident?(run) do
      cond do
        step.name == "Code Investigator" and Prompt.project_dir(run) == nil ->
          "there's no repository to search"

        step.name == "Evidence Analyst" and quick_check?(run) and Factory.Evidence.list(run) == [] ->
          "a quick check of one error, with nothing attached to read"

        true ->
          nil
      end
    end
  end

  defp skip_reason(_run, _step), do: nil

  defp incident?(run) do
    case Workflows.for_run(run) do
      nil -> false
      workflow -> Workflows.kind(workflow) == "incident"
    end
  end

  # The Triage Lead's plan says the track: "**Track:** Quick check …".
  defp quick_check?(run), do: (run.spec || "") =~ ~r/track:\**\s*quick check/i

  # A skipped step hands on what was handed to it.
  defp skip(run, steps, step, rest, why) do
    passed =
      step.after
      |> Enum.map(&run.progress["outputs"][&1])
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    progress =
      run.progress
      |> Map.update!("done", &(&1 ++ [step.id]))
      |> Map.update!("outputs", &Map.put(&1, step.id, passed))
      |> Map.update("skipped", [step.id], &Enum.uniq(&1 ++ [step.id]))

    {:ok, run} = Runs.update_run(run, %{progress: progress})
    Runs.post(run, "factory", "#{step.name} skipped: #{why}.", meta: meta(step))
    walk(run, steps, rest)
  end

  defp run_step(run, steps, step, rest) do
    if run.status == "running" do
      # A verdict from an earlier pass of this step mustn't decide this one.
      progress =
        run.progress
        |> Map.put("current", step.id)
        |> Map.update("verdicts", %{}, &Map.delete(&1, step.id))

      {:ok, run} = Runs.update_run(run, %{progress: progress})

      case timed_step(run, steps, step) do
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
              else
                {:ok, run}
              end

            # Paused or cancelled while its tasks were verified: what was checked is
            # kept, and nothing is opened again.
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
           Prompt.marks_tasks?(run, step),
         do:
           Enum.filter(
             run.tasks,
             &(&1.status == "done" and get_in(results, ["#{&1.id}", "passed"]) != true)
           ),
         else: []

    if todo == [] do
      {:ok, run}
    else
      # Marked while it checks, so a run paused meanwhile finishes the checks on resume.
      {:ok, run} = Runs.update_run(run, %{progress: Map.put(run.progress, "verifying", step.id)})

      case verify_each(run, step, output, todo) do
        :stopped ->
          :stopped

        {outcome, run} ->
          run = Runs.get_run(run.id)
          {:ok, run} = Runs.update_run(run, %{progress: Map.delete(run.progress, "verifying")})
          {outcome, run}
      end
    end
  end

  defp verify_each(run, step, output, todo) do
    model = Kiro.verify_model()
    dir = Kiro.workdir(run)
    name = Kiro.model_name(model)
    count = if length(todo) == 1, do: "the task", else: "#{length(todo)} tasks"

    set_activity(step.agent, "running", "Verifying “#{run.title}”")

    Runs.post(run, "factory", "Verifying #{count} #{step.name} finished, with #{name}.",
      meta: meta(step)
    )

    # Pausing or cancelling takes effect between tasks, as it does while building.
    checked =
      todo
      |> Enum.reduce_while([], fn task, checked ->
        if Runs.get_run(run.id).status == "running" do
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
        else
          {:halt, checked}
        end
      end)
      |> Enum.reverse()

    record =
      Map.new(checked, fn {task, result} -> {"#{task.id}", verification(result, model)} end)

    run = Runs.get_run(run.id)
    progress = Map.update(run.progress, "verification", record, &Map.merge(&1, record))
    {:ok, run} = Runs.update_run(run, %{progress: progress})

    for {task, result} <- checked, do: say_verified(run, step, task, result, name)

    failed = for {task, {:ok, %{passed: false} = r}} <- checked, do: {task, r}

    cond do
      # Stopped while the last one was checked, or before one: nothing goes back.
      run.status != "running" ->
        set_activity(step.agent, "idle", nil)
        :stopped

      failed == [] ->
        set_activity(step.agent, "done", nil)
        {:ok, run}

      true ->
        set_activity(step.agent, "done", nil)
        verify_failed(run, step, failed)
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
          "Task #{Prompt.number(task)} verified by #{name}: #{passed} of #{length(r.checks)} checks passed.",
        else: "Task #{Prompt.number(task)} failed verification by #{name}: #{r.fix}"

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
      "#{name} couldn't verify task #{Prompt.number(task)}, so it stays done unchecked: #{reason}",
      meta: meta(step)
    )
  end

  defp verify_failed(run, step, failed) do
    rounds = get_in(run.progress, ["verify_rounds", step.id]) || 0
    max_rounds = max_rounds()
    run = Runs.reopen_tasks(run, Enum.map(failed, fn {task, _} -> task.id end))
    Runs.tasks_changed(run)
    which = Enum.map_join(failed, ", ", fn {task, _} -> Prompt.number(task) end)

    if rounds < max_rounds do
      fix =
        Enum.map_join(failed, "\n\n", fn {task, r} ->
          misses =
            for c <- r.checks, !c["passed"] do
              "- #{c["check"]}" <> if(c["evidence"] != "", do: ": #{c["evidence"]}", else: "")
            end

          Enum.join(
            ["Task #{Prompt.number(task)}, #{task.title}: #{r.fix}" | misses],
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

  @doc """
  "what to fix" when a reply's last line is "Send back: what to fix", else nil. "Send
  back" must be the words on their own (not "Send backup…"), and "Send back: none" isn't
  a send-back.
  """
  def verdict(output) do
    last =
      output |> String.split("\n") |> Enum.reverse() |> Enum.find("", &(String.trim(&1) != ""))

    case Regex.run(~r/^\W*send back(?:\s*[:\-—–]\s*|\W*$)(.*?)\W*$/iu, String.trim(last)) do
      [_, ""] -> String.trim(output)
      [_, fix] -> if Regex.match?(~r/^(none|nothing|n\/?a)$/i, fix), do: nil, else: fix
      nil -> nil
    end
  end

  # Each step's duration and outcome go out as `[:factory, :run, :step, :stop]`, with
  # the run and the agent in its metadata (see `FactoryWeb.Telemetry.metrics/0`).
  defp timed_step(run, steps, step) do
    meta = %{run_id: run.id, agent_kind: step.kind, agent_name: step.name}

    :telemetry.span([:factory, :run, :step], meta, fn ->
      result = do_step(run, steps, step)
      {result, Map.put(meta, :outcome, step_outcome(result))}
    end)
  end

  defp step_outcome({:ok, _output, _sent}), do: :ok
  defp step_outcome({:error, _reason}), do: :error
  defp step_outcome(:stopped), do: :stopped

  defp do_step(run, _steps, %{kind: "action", agent: card} = step) do
    set_activity(card, "running", "Running for “#{run.title}”")
    # What the agents wrote goes out (a pull request, a message): without any secret
    # one of them read and repeated.
    ctx = Actions.context(run) |> Map.put("summary", Factory.Redact.secrets(summary(run, step)))

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
    case Prompt.marks_tasks?(run, step) && own_tasks(run, steps, step) do
      [_ | _] = tasks -> build_each(run, steps, step, tasks)
      _ -> one_pass(run, steps, step)
    end
  end

  defp one_pass(run, steps, step) do
    set_activity(step.agent, "running", "Working on “#{run.title}”")
    Runs.post(run, "factory", "#{step.name} is on it#{handed_by(steps, step)}.", meta: meta(step))
    prompt = Prompt.fit(run, steps, step)

    # On the agent's own Kiro session, which posts the reply to the chat and keeps the
    # conversation for a later pass. The prompt carries its sources and instructions.
    activity = "Working on “#{run.title}”"

    opts =
      step_opts(run, step, prompt, model(run, step), activity, Prompt.marks_tasks?(run, step))

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
    names = Enum.map_join(tasks, ", ", fn {task, _} -> Prompt.number(task) end)

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

        # Paused, cancelled, or past its credit limit between tasks, as between steps: a
        # step with many tasks could otherwise use far more than the limit.
        cond do
          run.status != "running" ->
            {:halt, :stopped}

          spent = Credits.over(run) ->
            Credits.pause(run, step, spent, "#{step.name}'s task #{Prompt.number(task)}")
            {:halt, :stopped}

          true ->
            model = task_model(run, step, block)

            activity =
              if count == 1,
                do: "Building task #{Prompt.number(task)} of “#{run.title}”",
                else: "Building task #{Prompt.number(task)} (#{n} of #{count}) of “#{run.title}”"

            set_activity(step.agent, "running", activity)
            prompt = Prompt.fit(run, steps, step, {task, block})

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
        # A generator, not `owner = …`: a nil owner (a task given to nobody) would
        # filter the task out.
        owner <- [block[:agent] && String.downcase(block.agent)],
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

  @doc "What an agent step is asked to do. Public for tests."
  def prompt(run, steps, step), do: Prompt.fit(run, steps, step).text

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
          ran_note(steps, run.progress["skipped"] || []) <>
            tasks_note(run.tasks, steps) <> verified_note(run),
          # Troubleshooting ends with a report; Fix it starts a Fix a bug run on it.
          actions: if(incident?(run), do: ["fix_it"], else: [])
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

  defp ran_note(steps, []),
    do:
      "Done: all #{length(steps)} #{if length(steps) == 1, do: "step", else: "steps"} of the workflow ran."

  defp ran_note(steps, skipped),
    do:
      "Done: #{length(steps) - length(skipped)} of the workflow's #{length(steps)} steps ran; " <>
        "#{length(skipped)} had nothing to do."

  # Tasks are done when an agent marked them (`Factory.RunTools`), not because the run ended.
  # In a workflow whose agents only read (a review, troubleshooting) they're checks to
  # work through, and nobody marks them.
  defp tasks_note([], _steps), do: ""

  defp tasks_note(tasks, steps) do
    if Enum.any?(steps, &Prompt.marks_tasks?(%{tasks: tasks}, &1)),
      do: tasks_note(tasks),
      else: ""
  end

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

    next =
      if Factory.Kiro.usage_limited?(reason),
        do: "Kiro answers nothing until its usage limit resets: /resume then.",
        else: "Fix the cause, then /resume to try it again."

    Runs.post(
      run,
      "factory",
      "#{step.name} failed: #{reason}\nThe run is paused at this step. #{next}",
      meta: meta(step)
    )
  end

  defp say(run, step, text),
    do: Runs.post(run, "factory", String.trim(text), author: step.name, meta: meta(step))

  defp meta(%{agent: %{id: id}}), do: %{"agent_id" => id}
  defp meta(_), do: %{}

  defp set_activity(nil, _status, _activity), do: :ok
  defp set_activity(card, status, activity), do: Agents.set_activity(card.id, status, activity)

  @doc """
  Runs left "running" or "queued" when Factory stopped have no worker any more: pauses
  each, keeps why in its progress (`"error"`), says so in its chat and sets the agent
  it was on idle, so it can be resumed by hand with /resume. Run once at boot
  (`Factory.Application`), after the database and PubSub are up. Returns how many runs
  it paused, which also goes out as `[:factory, :run, :recovered]`.
  """
  def recover do
    import Ecto.Query

    ids =
      Factory.Repo.all(
        from r in Run, where: r.status in ["running", "queued"], order_by: r.id, select: r.id
      )

    recovered =
      Enum.count(ids, fn id ->
        match?({:ok, :recovered}, Runs.with_locked_run(id, &recover_locked/1))
      end)

    if recovered > 0,
      do: Logger.info("Paused #{recovered} run(s) left over from before the restart")

    :telemetry.execute([:factory, :run, :recovered], %{count: recovered}, %{})
    recovered
  end

  # Under the row lock: a run that was resumed or cancelled meanwhile is left alone, and
  # so is one a worker owns already.
  defp recover_locked(%Run{status: status} = run) when status in ["running", "queued"] do
    if running?(run.id), do: {:ok, :unchanged}, else: recover_now(run, status)
  end

  defp recover_locked(_run), do: {:ok, :unchanged}

  defp recover_now(run, status) do
    reason = "Factory restarted while this run was #{status}"
    progress = Map.put(run.progress || %{}, "error", reason)
    {:ok, run} = Runs.update_run(run, %{status: "paused", progress: progress})

    # `{:error, :gone}` when the run went meanwhile: nothing more to say then.
    Runs.post(run, "factory", "Factory restarted. Type /resume to carry on.")

    case Enum.find(steps(run), &(&1.id == run.progress["current"])) do
      %{agent: card} -> set_activity(card, "idle", nil)
      nil -> :ok
    end

    {:ok, :recovered}
  end
end
