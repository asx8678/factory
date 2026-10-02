defmodule Factory.ChatPlanner do
  @moduledoc """
  Planning in a chat: what the person writes to the workflow's planner is turned into
  tasks, on the planner's own Kiro session (`Factory.Kiro.run_step/4`), so later
  messages keep the conversation; a one-off `Kiro.ask` when that session is busy in
  another folder. The planner (on Kiro, read-only, in the chat's project folder) rethinks how
  it's best done from everything asked so far, the spec files attached and the plan so
  far. It writes the plan with Factory's tools as it goes (`Factory.PlanTools`): a
  summary and approach, then the tasks a few at a time, or changes to the tasks already
  there, so edits the person made to them are kept. It can ask questions instead. Its
  closing message asks whether to implement the tasks (the "start" action).

  Spec files attached in the chat and the plan go into the run's spec
  (`Factory.Specs.for_run/1`), which opens on the Spec page to edit. While it works,
  the planner's live bubble shows what it's doing and the tasks so far
  (`{:agent_stream, …}` on `"run:ID"`). If Kiro can't reach the tools, the planner
  replies with the whole plan as JSON, which replaces the tasks as before.
  """
  import Ecto.Query, only: [from: 2]
  alias Factory.{Agents, Kiro, PlanTools, Repo, Runs, Specs, Text}
  alias Factory.Runs.Run
  alias Factory.Specs.{Planner, TaskCheck}
  alias Factory.Specs.Spec, as: SpecDoc

  @doc """
  Whether a chat message is a plan review asked with the Review plan button, which
  earlier versions posted to the chat (marked `"kind" => "review"`, or before that only
  by its opening). Such a message isn't something the person wrote.
  """
  def review_message?(%{role: "user", meta: %{"kind" => "review"}}), do: true

  def review_message?(%{role: "user", body: body}) when is_binary(body),
    do: String.starts_with?(body, "Look at the code again and improve this plan.")

  def review_message?(_message), do: false

  @doc "Adds spec files attached in the chat to the run's spec, for the planner to read."
  def keep_files(%Run{} = run, files) do
    with {:ok, spec} <- Specs.ensure_for_run(run),
         {:ok, _spec} <- Specs.add_files(spec, files) do
      :ok
    else
      {:error, _} ->
        names = Enum.map_join(files, ", ", &elem(&1, 0))
        Runs.post(run, "factory", "I couldn't store #{names}. Try attaching it again.")
    end

    Runs.get_run(run.id) || run
  end

  @doc """
  Plans in the background; the reply is posted to the run. `action:` is a button in
  the chat's plan, which the planner is asked in place of a message (it isn't posted
  to the chat nor counted among the person's requests):

    * `:scope` checks the scope of work: it reads the code and reports, and the plan
      tools only read the plan. The report is posted as it is, marked `"check" => true`.
    * `:grill` grills the code about what was asked (`Factory.Specs.Planner`) and
      reports the same way, marked `"check_kind" => "grill"` too; what only the person
      can decide it asks them, on the spot or with the report.
    * `:refine` reworks the plan in place (it can't be replaced), acting on
      `findings:`, the scope check shown with the plan, if any.

  Both are told which tasks Factory's own rules find thin (`Factory.Specs.TaskCheck`).
  """
  def start(%Run{} = run, planner, opts \\ []) do
    mode = opts[:action]

    with {:ok, {run, files, prompt}} <- prepare(run, planner, mode, opts[:findings]) do
      start_request(run, planner, files, prompt, mode)
    end
  end

  # What the planner is given of the person's messages: the latest whole (up to a size
  # each), earlier ones cut short, as a long chat (pasted logs, many answers) would
  # otherwise grow every replan's prompt past what the model can take.
  @recent_requests 8
  @recent_bytes 48_000
  @older_bytes 2_000
  @file_bytes 96_000

  defp bounded_requests(requests) do
    older = max(length(requests) - @recent_requests, 0)

    requests
    |> Enum.with_index()
    |> Enum.map(fn {text, i} ->
      max = if i < older, do: @older_bytes, else: @recent_bytes
      Factory.Context.Bounds.clip(text, max, " … [cut short]")
    end)
  end

  defp bounded_files(files),
    do:
      Enum.map(files, fn {name, text} ->
        {name, Factory.Context.Bounds.clip(text, @file_bytes, "\n… [the rest is left out]")}
      end)

  # Under the run's lock: the run's spec (made now if it has none), the prompt, and
  # the run with what was asked so far as its description.
  defp prepare(run, planner, mode, findings) do
    Runs.with_locked_run(run.id, fn run ->
      with true <- run.status == "draft" || {:error, :not_draft},
           {:ok, spec} <- Specs.ensure_for_run(run) do
        requests =
          for m <- Runs.list_messages(run.id),
              m.role == "user",
              text = String.trim(m.body),
              text != "" and not String.starts_with?(text, "/"),
              # Review requests posted before they became internal aren't requests.
              not review_message?(m),
              do: text

        # Base specs are rules, not part of the run's own files.
        files = Enum.reject(Specs.files(spec), &(elem(&1, 0) == "tasks.md"))
        base = Specs.base_files_for_run(run)
        current = if Specs.tasks(spec) == [], do: nil, else: PlanTools.describe(spec, :full)

        action = mode && %{mode: mode, thin: thin_tasks(spec), findings: findings}

        # What the chat plans for: a review plans checks, not changes.
        workflow = Factory.Workflows.for_run(run)
        job = workflow && Factory.Workflows.kind(workflow)
        # Who can build: each task is given to one of them, with its model.
        agents = Factory.Workflows.builders(workflow)
        # Troubleshooting says which mode it's in: a repository, or none.
        mode_line =
          job == "incident" &&
            Enum.join(
              Enum.reject(
                [
                  Factory.Runs.Troubleshooting.mode_line(
                    case String.trim(run.settings["project_dir"] || "") do
                      "" -> nil
                      dir -> dir
                    end
                  ),
                  Factory.Evidence.describe(run)
                ],
                &is_nil/1
              ),
              "\n"
            )

        prompt_args = [
          planner.name,
          bounded_requests(requests),
          bounded_files(base ++ files),
          current,
          action,
          job,
          agents,
          mode_line || nil
        ]

        prompt = %{
          full: apply(Planner, :chat_prompt, prompt_args),
          parts: apply(Planner, :chat_prompt_parts, prompt_args),
          doing: doing(mode, job, requests, run.title)
        }

        run =
          Runs.get_run(run.id)
          |> Ecto.Changeset.change(planner_generation: Ecto.UUID.generate())
          |> Repo.update!()

        with {:ok, run} <- Runs.update_run(run, %{description: Enum.join(requests, "\n\n")}) do
          {:ok, {run, files, prompt}}
        end
      end
    end)
  end

  # What the planner is doing, in words for its card and the chat's progress line: for
  # a review, what it's reviewing (the pull request, the branch…), never "planning".
  defp doing(:scope, _job, _requests, title), do: "Checking the scope of “#{title}”"
  defp doing(:grill, _job, _requests, title), do: "Grilling the code for “#{title}”"
  defp doing(:refine, "review", _requests, title), do: "Reworking the review of “#{title}”"

  defp doing(:refine, "incident", _requests, title),
    do: "Reworking the investigation of “#{title}”"

  defp doing(:refine, _job, _requests, title), do: "Refining “#{title}”"

  defp doing(_mode, "review", requests, title),
    do: Enum.find_value(Enum.reverse(requests), &review_target/1) || "Reviewing “#{title}”"

  defp doing(_mode, "incident", _requests, title), do: "Triaging “#{title}”"
  defp doing(_mode, _job, _requests, title), do: "Planning “#{title}”"

  # What a review request names, as the chat's buttons write it or as typed.
  defp review_target(text) do
    cond do
      m = Regex.run(~r{/pull/(\d+)}, text) ->
        "Reviewing pull request ##{Enum.at(m, 1)}"

      m = Regex.run(~r/\bpull request #(\d+)/i, text) ->
        "Reviewing pull request ##{Enum.at(m, 1)}"

      m = Regex.run(~r/\bbranch\s+`([^`]+)`/i, text) ->
        "Reviewing the branch #{Enum.at(m, 1)}"

      m = Regex.run(~r{\bbranch\s+([\w.]+[/-][\w./-]+)}i, text) ->
        "Reviewing the branch #{Enum.at(m, 1)}"

      text =~ ~r/uncommitted changes/i ->
        "Reviewing the uncommitted changes"

      m = Regex.run(~r/\blast (\d+) commits/i, text) ->
        "Reviewing the last #{Enum.at(m, 1)} commits"

      true ->
        nil
    end
  end

  # Each task Factory's rules find thin, by its number, with what it's missing: the same
  # tasks the chat's plan marks.
  defp thin_tasks(spec) do
    {_, tasks} = Factory.Spec.blocks(spec.tasks || "")

    for {task, i} <- Enum.with_index(tasks, 1), TaskCheck.thin?(task) do
      "Task #{i}, #{task.title}: #{Enum.join(TaskCheck.issues(task), ", ")}"
    end
  end

  defp start_request(run, planner, files, prompt, mode) do
    dir = Kiro.workdir(run)
    generation = run.planner_generation
    # What the live bubble needs that holds for the whole pass, read once.
    progress = progress(run)
    show = &show_progress(run.id, planner, &1, progress)

    prompt =
      prompt
      |> Map.put(:model, planning_model(planner))
      |> Map.put(:on_tool, &show.(Planner.describe_tool(&1, dir)))

    Agents.set_activity(planner.id, "running", prompt.doing)

    show.(
      if(String.starts_with?(prompt.doing, "Planning"),
        do: "Reading the project…",
        else: prompt.doing <> "…"
      )
    )

    Task.Supervisor.start_child(Factory.TaskSupervisor, fn ->
      # On the planner's own Kiro session, which keeps the conversation between
      # messages; a one-off session when that one is busy in another folder.
      result =
        Factory.Background.guard("Planning run #{run.id}", fn ->
          case plan_in_session(run, planner, prompt, generation, mode) do
            {:error, :busy} -> plan_once(run, planner, prompt, generation, dir, mode)
            result -> result
          end
        end)

      result =
        case result do
          {:ok, r} -> {:ok, Map.put(r, :check, check?(mode) && mode)}
          # A failure remembers what was asked, for its Try again.
          {:error, reason} -> {:error, reason, mode}
        end

      finish(run.id, generation, planner, files, result)
    end)

    :ok
  end

  defp plan_in_session(run, planner, prompt, generation, mode) do
    {brief, ask} = prompt.parts

    brief =
      if String.trim(brief) == "",
        do: nil,
        else: {brief, "chat:#{run.id}:" <> Factory.Context.sha256(brief)}

    reply =
      Kiro.run_step(planner, run.id, ask,
        brief: brief,
        source: "plan_chat",
        context: :skip,
        reply: :last,
        post: false,
        stream: false,
        activity: prompt.doing,
        model: prompt.model,
        on_tool: prompt.on_tool,
        planning: %{
          generation: generation,
          notify: self(),
          read_only: check?(mode),
          keep_plan: mode == :refine
        },
        on_busy: :return
      )

    with {:ok, reply} <- reply, do: read_result(reply, generation, check?(mode))
  end

  # The buttons that only read the plan and report: Scope and Grill code.
  defp check?(mode), do: mode in [:scope, :grill]

  defp plan_once(run, planner, prompt, generation, dir, mode) do
    token =
      PlanTools.grant(run.id, generation, planner,
        read_only: check?(mode),
        keep_plan: mode == :refine
      )

    with {:ok, reply} <-
           Kiro.ask(prompt.full,
             workdir: dir,
             model: prompt.model,
             allow: ["read", "search", "look"],
             # A troubleshooting run's attached files are there to read.
             roots: [Factory.Evidence.dir(run)],
             mcp_servers: [PlanTools.mcp_server(token)],
             reply: :last,
             on_tool: prompt.on_tool,
             usage: %{source: "plan_chat", run_id: run.id, agent_id: planner.id}
           ) do
      read_result(reply, generation, check?(mode))
    end
  end

  # Plans on the planning model (Settings), unless the planner's card names its own.
  defp planning_model(planner) do
    if planner.model in Kiro.models() and planner.model != "auto",
      do: planner.model,
      else: Kiro.planning_model()
  end

  # What the tools reported while Kiro worked (`Factory.PlanTools`). Without any tool
  # call, the reply is the JSON plan the prompt asks for when the tools are missing, or
  # just an answer that leaves the plan as it is.
  # A check's reply is what it found, never a plan to apply. What it asked the person
  # and they didn't answer on the spot goes with it.
  defp read_result(reply, generation, true) do
    questions = for {:questions, qs} <- tool_events(generation, []), q <- qs, do: q

    case String.trim(reply) do
      "" ->
        {:error, "The check ended without a reply."}

      reply ->
        {:ok,
         %{reply: reply, questions: Enum.take(questions, Planner.max_questions()), written: true}}
    end
  end

  defp read_result(reply, generation, false) do
    reply = String.trim(reply)

    case tool_events(generation, []) do
      [] ->
        case Planner.parse_chat_plan(reply) do
          {:ok, plan} ->
            {:ok, plan}

          {:error, _} when reply != "" ->
            {:ok, %{reply: reply, questions: [], written: true}}

          {:error, _} ->
            {:error, "The planner ended without a plan or a reply."}
        end

      events ->
        questions = for {:questions, qs} <- events, q <- qs, do: q

        {:ok,
         %{reply: reply, questions: Enum.take(questions, Planner.max_questions()), written: true}}
    end
  end

  defp tool_events(generation, acc) do
    receive do
      {:plan_tools, ^generation, event} -> tool_events(generation, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc false
  def finish(run_id, generation, planner, files, result) do
    Runs.with_locked_run(run_id, fn run ->
      if run.status == "draft" and not is_nil(generation) and
           run.planner_generation == generation do
        finish(run, planner, files, result)
        run |> Ecto.Changeset.change(planner_generation: nil) |> Repo.update!()
        {:ok, :applied}
      else
        {:ok, :stale}
      end
    end)
  end

  # A check (Scope, Grill code): what it found goes to the chat as it is; the plan is
  # unchanged. A grill's questions the person hasn't answered are asked under it.
  defp finish(run, planner, _files, {:ok, %{check: kind, reply: reply} = result})
       when kind in [:scope, :grill] do
    Agents.set_activity(planner.id, "idle", nil)
    questions = Map.get(result, :questions, [])

    post(run, planner, reply, %{
      "check" => true,
      "check_kind" => to_string(kind),
      "questions" => questions
    })
  end

  # Written with the tools: the spec already has the plan. With no tasks yet, it's the
  # questions to answer first; with tasks, questions are asked alongside them.
  defp finish(run, planner, files, {:ok, %{written: true, reply: reply, questions: questions}}) do
    Agents.set_activity(planner.id, "idle", nil)
    titles = Enum.map(Runs.get_run(run.id).tasks, & &1.title)

    if titles == [] do
      ask(run, planner, reply, questions)
    else
      post(
        run,
        planner,
        with_questions(Text.or_default(reply, "Here's how I'd do it."), questions),
        %{"tasks" => titles, "spec_hint" => files == [], "questions" => questions},
        ["start"]
      )
    end
  end

  # Not clear enough to plan: no tasks, but what's missing and the questions to answer.
  defp finish(run, planner, _files, {:ok, %{reply: reply, tasks: [], questions: questions}}) do
    Agents.set_activity(planner.id, "idle", nil)
    ask(run, planner, reply, questions)
  end

  # The plan replaces the spec's tasks: the planner rethinks it from everything asked.
  # Tasks approved on the Spec page stay as they are, as with the plan tools.
  defp finish(run, planner, files, {:ok, %{reply: reply, tasks: tasks} = plan}) do
    case Specs.ensure_for_run(run) do
      {:ok, spec} ->
        if SpecDoc.approved?(spec, "tasks") do
          Agents.set_activity(planner.id, "idle", nil)

          post(
            run,
            planner,
            Text.or_default(reply, "Here's how I'd do it.") <>
              "\n\nThe tasks are approved on the Spec page, so I left them as they are. " <>
              "Reopen them there to change them.",
            %{}
          )
        else
          save_plan(run, planner, files, spec, reply, tasks, Map.get(plan, :questions, []))
        end

      {:error, _} ->
        finish(run, planner, files, {:error, "the plan couldn't be saved."})
    end
  end

  defp finish(run, planner, files, {:error, reason}),
    do: finish(run, planner, files, {:error, reason, nil})

  # The chat's Try again (`Factory.Chat.retry/2`) plans again the same way (a scope
  # check, a refine, or the plan), once whatever stopped it is fixed.
  defp finish(run, planner, _files, {:error, reason, mode}) do
    Agents.set_activity(planner.id, "error", reason)
    hint = if reason =~ ~r/try again/i, do: "", else: " Try again, or say it differently."

    post(
      run,
      planner,
      "I couldn't plan it: #{reason}#{hint}",
      %{"retry" => %{"kind" => "plan", "action" => mode && to_string(mode)}},
      ["retry"]
    )
  end

  # Questions asked alongside the tasks are shown with them, as with the tools.
  defp save_plan(run, planner, files, spec, reply, tasks, questions) do
    saved =
      with {:ok, spec} <-
             Specs.update_spec(spec, %{tasks: Planner.to_markdown(tasks, 1) <> "\n"}),
           do: Specs.follow_tasks(spec)

    case saved do
      {:ok, spec} ->
        run = Runs.get_run(run.id) || run
        Agents.set_activity(planner.id, "idle", nil)

        post(
          run,
          planner,
          with_questions(Text.or_default(reply, "Here's how I'd do it."), questions),
          %{
            # As saved: a repeated title got a count (`Factory.Specs.Planner.to_markdown/2`).
            "tasks" => Enum.map(Specs.tasks(spec), & &1.title),
            "spec_hint" => files == [],
            "questions" => questions
          },
          ["start"]
        )

      {:error, _} ->
        finish(run, planner, files, {:error, "the plan couldn't be saved."})
    end
  end

  defp ask(run, planner, reply, questions) do
    body =
      with_questions(
        Text.or_default(reply, "I need a bit more information before I can plan this."),
        questions
      )

    post(run, planner, body, %{"unclear" => questions != [], "questions" => questions})
  end

  defp with_questions(body, []), do: body

  defp with_questions(body, questions) do
    listed =
      questions
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {q, i} ->
        options = if q["options"] == [], do: "", else: " (#{Enum.join(q["options"], " / ")})"
        "#{i}. #{q["question"]}#{options}"
      end)

    body <> "\n\n" <> listed
  end

  defp post(run, planner, body, meta, actions \\ []) do
    Runs.post(run, "factory", body,
      author: planner.name,
      meta: Map.put(meta, "agent_id", planner.id),
      actions: actions
    )
  end

  @doc """
  Shows in the planner's live bubble what it's doing (`activity`) and the tasks so far,
  read from the run's spec. `planner` needs its `id` and `name`.
  """
  def show_progress(run_id, planner, activity),
    do: show_progress(run_id, planner, activity, progress(Repo.get(Run, run_id)))

  # What the bubble needs that holds while the planner works: whether the run is a
  # review, and the spec its tasks are in. A pass reads it once, not on every tool call.
  defp progress(%Run{} = run), do: %{review?: review?(run), spec_id: run.spec_id}
  defp progress(nil), do: %{review?: false, spec_id: nil}

  defp show_progress(run_id, planner, activity, %{review?: review?, spec_id: spec_id}) do
    # The plan tools report `:writing` as the planner writes the plan.
    activity =
      case activity do
        :writing -> if review?, do: "Listing what to check…", else: "Planning…"
        text -> text
      end

    # Only the tasks' text: they change as the planner writes them.
    tasks =
      with id when is_integer(id) <- spec_id,
           text when is_binary(text) <-
             Repo.one(from s in SpecDoc, where: s.id == ^id, select: s.tasks),
           [_ | _] = tasks <- Factory.Spec.parse_tasks(text) do
        "\n\n**#{if review?, do: "Checks so far", else: "Tasks so far"}**\n\n" <>
          (tasks
           |> Enum.with_index(1)
           |> Enum.map_join("\n", fn {t, i} -> "#{i}. #{t.title}" end))
      else
        _ -> ""
      end

    text = "_#{activity}_" <> tasks

    Phoenix.PubSub.broadcast(
      Factory.PubSub,
      "run:#{run_id}",
      {:agent_stream,
       %{run_id: run_id, agent_id: planner.id, name: planner.name, text: text, activity: activity}}
    )
  end

  defp review?(run) do
    case Factory.Workflows.for_run(run) do
      nil -> false
      workflow -> Factory.Workflows.kind(workflow) == "review"
    end
  end
end
