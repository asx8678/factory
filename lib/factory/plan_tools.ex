defmodule Factory.PlanTools do
  @moduledoc """
  Tools a planner on Kiro uses to write a chat's plan as it works: it creates the plan
  (a summary and its approach), then adds tasks to it a few at a time, and refines them
  on later messages. Kiro reaches them over MCP (`FactoryWeb.MCP`).

  Each planning request gets a token (`grant/3`) naming its run, the run's
  `planner_generation` and the process waiting for Kiro. A call only writes while the run
  is a draft and that generation is still the latest, so a replaced request can't change
  the plan. The plan lives in the run's spec (`Factory.Specs.for_run/1`): the approach in
  its design, the tasks in its tasks step, which the draft run follows.

  The waiting process gets `{:plan_tools, generation, event}` for each call that worked:
  `:changed` after a write, `{:questions, [question]}` from `ask_user`.
  """
  import Factory.PromptText, only: [text: 1]
  alias Factory.{Runs, Spec, Specs}
  alias Factory.Specs.Planner
  alias Factory.Specs.Spec, as: SpecDoc

  @server "factory"
  @salt "factory plan tools"
  @max_tasks 40
  # The approach the planner writes opens the spec's design with this heading, so a
  # design the person wrote is never replaced.
  @approach "# Approach"

  @tools [
    %{
      name: "get_plan",
      description: "The current plan: its approach and its numbered tasks.",
      inputSchema: %{type: "object", properties: %{}}
    },
    %{
      name: "create_plan",
      description:
        "Starts a new plan with a summary and your approach, replacing the current tasks. " <>
          "Call it once, before add_tasks, when there is no plan yet or the person wants a " <>
          "different one; to change the current plan use update_task, remove_tasks and add_tasks.",
      inputSchema: %{
        type: "object",
        properties: %{
          summary: %{type: "string", description: "One or two sentences: what will be built."},
          approach: %{
            type: "string",
            description:
              "Markdown: the parts of the code that change, the approach, risks and how it will be tested."
          }
        },
        required: ["summary", "approach"]
      }
    },
    %{
      name: "add_tasks",
      description:
        "Adds implementation tasks to the plan, in build order, at the end or after task " <>
          "number `after` (0 for the start). Add a few at a time (2 to 5). Each task is one " <>
          "change that can be built and verified on its own: what's true when it's done " <>
          "(objective), the steps naming the files it changes (details), how to check it " <>
          "(verify) and the model to build it with.",
      inputSchema: %{
        type: "object",
        properties: %{
          tasks: %{
            type: "array",
            minItems: 1,
            items: %{
              type: "object",
              properties: %{
                title: %{type: "string", description: "Imperative, under 80 characters."},
                objective: %{
                  type: "string",
                  description: "One or two sentences: what is true when it's done."
                },
                details: %{
                  type: "array",
                  items: %{type: "string"},
                  description:
                    "The approach: steps in order, naming the files and functions each changes, " <>
                      "1 to 8. Wrap code and paths in `backticks`."
                },
                verify: %{
                  type: "array",
                  items: %{type: "string"},
                  description:
                    "1 to 4 checks that prove it's done: a command and what it must show, a " <>
                      "test that must pass, or what to look at."
                },
                agent: %{
                  type: "string",
                  description:
                    "Which of the workflow's agents builds it, as the prompt lists them."
                },
                model: %{
                  type: "string",
                  description: "The model to build it with, from the ones the prompt lists."
                },
                requirements: %{
                  type: "array",
                  items: %{type: "string"},
                  description: "Requirement numbers it covers, e.g. 1.2."
                }
              },
              required: ["title"]
            }
          },
          after: %{type: "integer", description: "Insert after this task number."}
        },
        required: ["tasks"]
      }
    },
    %{
      name: "update_task",
      description:
        "Changes task `number`. Fields left out stay as they are, so edits the person made are kept.",
      inputSchema: %{
        type: "object",
        properties: %{
          number: %{type: "integer"},
          title: %{type: "string"},
          objective: %{type: "string"},
          details: %{type: "array", items: %{type: "string"}, description: "The steps."},
          verify: %{type: "array", items: %{type: "string"}, description: "The checks."},
          agent: %{type: "string", description: "Who builds it."},
          model: %{type: "string"},
          requirements: %{type: "array", items: %{type: "string"}}
        },
        required: ["number"]
      }
    },
    %{
      name: "remove_tasks",
      description: "Removes tasks by number. The rest are numbered again from 1.",
      inputSchema: %{
        type: "object",
        properties: %{numbers: %{type: "array", items: %{type: "integer"}, minItems: 1}},
        required: ["numbers"]
      }
    },
    %{
      name: "ask_user",
      description:
        "Asks the person 1 to 5 short questions when the request isn't clear enough to plan " <>
          "without guessing. They're shown when your turn ends; the answers come as the next message.",
      inputSchema: %{
        type: "object",
        properties: %{
          questions: %{
            type: "array",
            minItems: 1,
            items: %{
              type: "object",
              properties: %{
                question: %{type: "string"},
                options: %{
                  type: "array",
                  items: %{type: "string"},
                  description:
                    "2 to 4 short options, where that helps; the one you recommend first."
                }
              },
              required: ["question"]
            }
          }
        },
        required: ["questions"]
      }
    }
  ]

  # Suggesting tasks on the Spec page: Kiro adds them to a list to pick from
  # (`spec.plan["tasks"]`), not to the spec.
  @suggest_tool %{
    name: "suggest_tasks",
    description:
      "Adds suggested tasks to the list the person picks from, in build order, 3 to 6 at " <>
        "a time. Each task is one small change that can be built and tested on its own, " <>
        "names the files it touches and has a size: S, M or L.",
    inputSchema: %{
      type: "object",
      properties: %{
        tasks: %{
          type: "array",
          minItems: 1,
          items: %{
            type: "object",
            properties: %{
              title: %{type: "string", description: "Imperative, under 80 characters."},
              details: %{type: "array", items: %{type: "string"}},
              requirements: %{type: "array", items: %{type: "string"}},
              size: %{type: "string", enum: ["S", "M", "L"]}
            },
            required: ["title"]
          }
        }
      },
      required: ["tasks"]
    }
  }

  @doc "The tools, as MCP `tools/list` gives them."
  def tools, do: @tools

  @doc "The tools `token` has: the suggestion tool for a suggestion token, else the plan tools."
  def tools(token) do
    case verify(token) do
      {:ok, %{suggest: _}} -> [@suggest_tool]
      _ -> @tools
    end
  end

  @doc """
  A token for one round of suggestions on the Spec page: calls add to spec `spec_id`'s
  suggestions while its plan is being written under `ref` (`Factory.Specs.plan_tasks/2`).
  """
  def grant_suggest(spec_id, ref),
    do: Phoenix.Token.sign(FactoryWeb.Endpoint, @salt, %{suggest: spec_id, ref: ref})

  @doc "The name Kiro knows the tools' MCP server by."
  def server_name, do: @server

  @doc """
  A token for one planning request: calls with it write to run `run_id` while its
  `planner_generation` is `generation`, and are reported to the calling process.
  """
  def grant(run_id, generation, planner, opts \\ []) do
    Phoenix.Token.sign(FactoryWeb.Endpoint, @salt, %{
      run_id: run_id,
      generation: generation,
      planner: %{id: planner.id, name: planner.name},
      pid: self(),
      # A scope check reads the plan and may ask, but doesn't change it.
      read_only: Keyword.get(opts, :read_only, false),
      # Refine changes the plan in place; it can't replace it.
      keep_plan: Keyword.get(opts, :keep_plan, false)
    })
  end

  @reading_tools ~w(get_plan ask_user)
  @writing_tools ~w(create_plan add_tasks update_task remove_tasks)

  # What a button's turn may not do: a scope check changes nothing, and Refine keeps the
  # plan it reworks, with the person's edits. nil when the call may go ahead.
  defp refusal(%{read_only: true}, name) when name not in @reading_tools,
    do:
      {:error,
       "This is a check: report what you'd change in your reply, and leave the plan as it is."}

  defp refusal(%{keep_plan: true}, "create_plan"),
    do:
      {:error,
       "You're refining this plan, so it can't be replaced: change it with update_task, remove_tasks and add_tasks."}

  defp refusal(_turn, _name), do: nil

  @doc "The MCP server to give a Kiro session (ACP `session/new`), with the token."
  def mcp_server(token) do
    %{
      type: "http",
      name: @server,
      url: url(),
      headers: [%{name: "Authorization", value: "Bearer " <> token}]
    }
  end

  # Kiro runs on this machine. "localhost" may resolve to IPv6 while Phoenix listens on IPv4.
  defp url do
    Application.get_env(:factory, :mcp_url) ||
      FactoryWeb.Endpoint.url()
      |> URI.parse()
      |> then(&if(&1.host == "localhost", do: %{&1 | host: "127.0.0.1"}, else: &1))
      |> URI.append_path("/mcp")
      |> URI.to_string()
  end

  @doc """
  Runs tool `name` with `args` for the request `token` was granted to:
  `{:ok, text}` for Kiro, or `{:error, text}` saying what to do instead.
  """
  def call(token, name, args) when is_map(args) do
    case verify(token) do
      {:ok, %{suggest: spec_id, ref: ref}} -> suggest(spec_id, ref, name, args)
      _ -> call_plan(token, name, args)
    end
  end

  def call(_token, _name, _args), do: {:error, "The arguments must be an object."}

  defp suggest(spec_id, ref, "suggest_tasks", args) do
    tasks =
      for raw <- List.wrap(args["tasks"]), t = Planner.task(raw), t != nil do
        Map.put(t, "size", if(is_map(raw) and raw["size"] in ~w(S M L), do: raw["size"]))
      end

    case tasks != [] && Specs.add_suggestions(spec_id, ref, tasks) do
      false -> {:error, "Give each task a title."}
      {:ok, count} -> {:ok, "Added. #{count} suggested so far. Add more, or end your turn."}
      {:error, :full} -> {:error, "That's 30 suggestions, the most there can be. End your turn."}
      {:error, _} -> {:error, "These suggestions were replaced or stopped. End your turn."}
    end
  end

  defp suggest(_spec_id, _ref, name, _args), do: {:error, "There's no tool #{name}."}

  defp call_plan(token, name, args) do
    with {:ok, grant} <- verify(token),
         true <- Enum.any?(@tools, &(&1.name == name)) || {:error, "There's no tool #{name}."} do
      result =
        Runs.with_locked_run(grant.run_id, fn run ->
          if run.status == "draft" and run.planner_generation == grant.generation do
            refusal(grant, name) || apply_tool(name, args, run)
          else
            {:error,
             "This plan was replaced by a newer request or the run has started. Stop and end your turn."}
          end
        end)

      case result do
        {:ok, {event, text}} ->
          send(grant.pid, {:plan_tools, grant.generation, event})

          if event == :changed,
            do: Factory.ChatPlanner.show_progress(grant.run_id, grant.planner, :writing)

          {:ok, text}

        {:error, text} when is_binary(text) ->
          {:error, text}

        {:error, _} ->
          {:error, "This chat no longer exists. End your turn."}
      end
    end
  end

  @doc """
  Runs tool `name` for a planner talking in its own Kiro session: a message in the chat,
  before or after the run started (`Factory.RunTools` passes session calls here). Only
  the agent that plans the run (`Factory.Chat.planner_for/1`) may change it. Once the
  run has started, the plan can be added to and changed but not replaced, and the
  run's tasks follow it, keeping what's done. Questions go in the reply.

  A planner's draft turn (`planning: %{generation:, notify:}`, from
  `Factory.ChatPlanner`) is checked like a one-off request: it only writes while the
  run is a draft on that generation, and `notify` gets `{:plan_tools, generation,
  event}` for each call that worked, questions included.
  """
  def call_in_turn(run_id, agent, name, args, planning \\ nil)

  # In a session the person can be asked now, mid-turn (MCP elicitation, through
  # `FactoryWeb.MCP` and the chat): `{:elicit, request, then}`. `then` gets the answer
  # (`%{"action" => …, "content" => …}`); without one, the questions are shown after
  # the turn as before, or left for the reply.
  def call_in_turn(_run_id, _agent, name, _args, %{read_only: true} = planning)
      when name not in @reading_tools,
      do: refusal(planning, name)

  def call_in_turn(_run_id, _agent, "create_plan", _args, %{keep_plan: true} = planning),
    do: refusal(planning, "create_plan")

  def call_in_turn(run_id, agent, "ask_user", args, planning) when is_map(args) do
    questions = questions(args)

    check =
      Runs.with_locked_run(run_id, fn run ->
        planner = Factory.Chat.planner_for(run)

        cond do
          run.status == "cancelled" ->
            {:error, "This run was cancelled. End your turn."}

          planner == nil or planner.id != agent.id ->
            {:error, "Only the run's planner asks about its plan."}

          planning != nil and
              (run.status != "draft" or run.planner_generation != planning.generation) ->
            {:error,
             "This plan was replaced by a newer request or the run has started. Stop and end your turn."}

          true ->
            {:ok, :asking}
        end
      end)

    case {questions, check} do
      {[], _} -> {:error, "Ask at least one question."}
      {_, {:error, text}} when is_binary(text) -> {:error, text}
      {_, {:error, _}} -> {:error, "This chat no longer exists. End your turn."}
      _ -> {:elicit, elicitation(questions), &after_answer(&1, questions, planning)}
    end
  end

  def call_in_turn(run_id, agent, name, args, planning) when is_map(args) do
    with true <- Enum.any?(@tools, &(&1.name == name)) || {:error, "There's no tool #{name}."} do
      result =
        Runs.with_locked_run(run_id, fn run ->
          planner = Factory.Chat.planner_for(run)

          cond do
            run.status == "cancelled" ->
              {:error, "This run was cancelled. End your turn."}

            planner == nil or planner.id != agent.id ->
              {:error,
               "Only #{(planner && planner.name) || "the workflow's planner"} changes this run's plan."}

            planning != nil and
                (run.status != "draft" or run.planner_generation != planning.generation) ->
              {:error,
               "This plan was replaced by a newer request or the run has started. Stop and end your turn."}

            planning != nil ->
              apply_tool(name, args, run)

            name == "ask_user" ->
              {:ok, {:read, "Ask them in your reply; the person answers in the chat."}}

            name == "create_plan" and run.status != "draft" ->
              {:error,
               "The run has started, so its plan can't be replaced. Change it with add_tasks, update_task and remove_tasks."}

            true ->
              apply_in_turn(name, args, run)
          end
        end)

      case result do
        {:ok, {event, text}} ->
          if planning do
            send(planning.notify, {:plan_tools, planning.generation, event})

            if event == :changed,
              do: Factory.ChatPlanner.show_progress(run_id, agent, :writing)
          end

          {:ok, text}

        {:error, text} when is_binary(text) ->
          {:error, text}

        {:error, _} ->
          {:error, "This chat no longer exists. End your turn."}
      end
    end
  end

  def call_in_turn(_run_id, _agent, _name, _args, _planning),
    do: {:error, "The arguments must be an object."}

  # The questions as an MCP elicitation form: one field each, a choice when it has options.
  defp elicitation(questions) do
    # A question with options also takes an answer of your own (`answer_N_other`), for
    # an option that asks for details or one that isn't there.
    fields =
      for {q, i} <- Enum.with_index(questions, 1) do
        field = %{type: "string", title: q["question"]}

        if q["options"] != [],
          do: [
            {"answer_#{i}", Map.put(field, :enum, q["options"])},
            {"answer_#{i}_other",
             %{type: "string", title: "Your own answer", description: "Optional"}}
          ],
          else: [{"answer_#{i}", field}]
      end
      |> List.flatten()

    properties = Map.new(fields)
    required = for {name, _} <- fields, not String.ends_with?(name, "_other"), do: name

    %{
      message:
        if(length(questions) == 1,
          do: "A question before I go on:",
          else: "#{length(questions)} questions before I go on:"
        ),
      schema: %{type: "object", properties: properties, required: required}
    }
  end

  defp after_answer(%{"action" => "accept", "content" => content}, questions, _planning)
       when is_map(content) do
    answers =
      for {q, i} <- Enum.with_index(questions, 1),
          answer =
            [content["answer_#{i}"], content["answer_#{i}_other"]]
            |> Enum.map(&String.trim(to_string(&1 || "")))
            |> Enum.reject(&(&1 == ""))
            |> Enum.join(": "),
          answer != "",
          do: "- #{q["question"]} #{answer}"

    {:ok, "The person answered:\n" <> Enum.join(answers, "\n") <> "\nCarry on with that."}
  end

  # Not answered now: a draft's planner shows them after the turn (`Factory.ChatPlanner`).
  defp after_answer(_answer, questions, %{generation: g, notify: pid}) do
    send(pid, {:plan_tools, g, {:questions, questions}})

    {:ok,
     "They didn't answer now; the questions are shown when your turn ends. End it now with a short message."}
  end

  defp after_answer(_answer, _questions, nil),
    do: {:ok, "They didn't answer now. Ask the questions in your reply and end your turn."}

  # Before the start the spec change carries over to the run by itself
  # (`Factory.Specs.update_spec/2`); after it, the run's tasks follow here.
  defp apply_in_turn(name, args, %{status: "draft"} = run), do: apply_tool(name, args, run)

  defp apply_in_turn(name, args, run) do
    with {:ok, {:changed, text}} <- apply_tool(name, args, run) do
      spec = Specs.for_run(run)

      {:ok, run} =
        Runs.attach_spec(run, Specs.files(spec), Specs.tasks(spec), keep_status: true)

      open = Enum.count(run.tasks, &(&1.status != "done"))

      next =
        if run.status == "done",
          do: " The run has finished: #{open} open; typing /run in the chat builds them.",
          else: " The run is under way: #{open} open; new ones are built when it's run again."

      {:ok, {:changed, text <> next}}
    end
  end

  defp verify(token) do
    case Phoenix.Token.verify(FactoryWeb.Endpoint, @salt, token || "", max_age: 86_400) do
      {:ok, grant} -> {:ok, grant}
      {:error, _} -> {:error, "Factory didn't recognise this session. End your turn."}
    end
  end

  defp apply_tool("get_plan", _args, run) do
    {:ok, {:read, describe(Specs.for_run(run))}}
  end

  # While the run is planned, tasks approved on the Spec page are closed to the planner
  # as they are to the chat's own edits (`Factory.Specs.edit_plan_task/4`). Once the run
  # has started, its plan grows as before (`call_in_turn/5`).
  defp apply_tool(name, args, run) when name in @writing_tools do
    spec = Specs.for_run(run)

    if run.status == "draft" and SpecDoc.approved?(spec, "tasks"),
      do:
        {:error,
         "The tasks were approved on the Spec page, so the plan can't change until they're " <>
           "reopened there. Say what you'd change in your reply and end your turn."},
      else: write_tool(name, args, spec)
  end

  defp apply_tool("ask_user", args, _run) do
    questions = questions(args)

    if questions == [],
      do: {:error, "Ask at least one question."},
      else:
        {:ok,
         {{:questions, Enum.take(questions, 5)},
          "They'll be shown when your turn ends. End it now with a short message."}}
  end

  defp write_tool("create_plan", args, spec) do
    summary = text(args["summary"])
    approach = text(args["approach"])

    if summary == "" do
      {:error, "Give the plan a summary."}
    else
      attrs = %{tasks: ""}

      attrs =
        if planner_design?(spec.design),
          do: Map.put(attrs, :design, "#{@approach}\n\n#{summary}\n\n#{approach}" |> finish()),
          else: attrs

      write(spec, attrs, "Plan created. Now add its tasks with add_tasks.")
    end
  end

  defp write_tool("add_tasks", args, spec) do
    {preamble, blocks} = checklist(spec.tasks)

    new = for t <- Planner.tasks(args["tasks"]), do: task_block(t)

    at = if is_integer(args["after"]), do: args["after"] |> max(0) |> min(length(blocks))

    cond do
      new == [] ->
        {:error, "Give each task a title."}

      length(blocks) + length(new) > @max_tasks ->
        {:error, "A plan holds at most #{@max_tasks} tasks. Merge small ones instead."}

      true ->
        blocks =
          if at, do: Enum.take(blocks, at) ++ new ++ Enum.drop(blocks, at), else: blocks ++ new

        write(spec, %{tasks: Spec.render_blocks(preamble, blocks)}, "Added.")
    end
  end

  defp write_tool("update_task", args, spec) do
    {preamble, blocks} = checklist(spec.tasks)
    number = args["number"]

    case is_integer(number) && number >= 1 && Enum.at(blocks, number - 1) do
      block when is_map(block) ->
        # Only what's given changes; the rest, maybe the person's edits, stays.
        changes =
          %{
            title: text(args["title"]) != "" && text(args["title"]),
            objective: is_binary(args["objective"]) && text(args["objective"]),
            details: is_list(args["details"]) && lines(args["details"]),
            verify: is_list(args["verify"]) && lines(args["verify"]) |> Enum.take(6),
            agent: is_binary(args["agent"]) && text(args["agent"]),
            model: is_binary(args["model"]) && task_model(args["model"]),
            requirements:
              is_list(args["requirements"]) && lines(args["requirements"]) |> Enum.take(8)
          }
          |> Map.reject(fn {_, v} -> v == false end)

        edited = Spec.edit_block(block, changes)
        blocks = List.replace_at(blocks, number - 1, edited)

        write(spec, %{tasks: Spec.render_blocks(preamble, blocks)}, "Changed task #{number}.", %{
          block.title => edited.title
        })

      _ ->
        {:error, "There's no task #{inspect(number)}. #{describe(spec)}"}
    end
  end

  defp write_tool("remove_tasks", args, spec) do
    {preamble, blocks} = checklist(spec.tasks)
    numbers = for n <- List.wrap(args["numbers"]), is_integer(n), do: n

    kept = for {block, i} <- Enum.with_index(blocks, 1), i not in numbers, do: block

    if length(kept) == length(blocks) do
      {:error, "None of those tasks exist. #{describe(spec)}"}
    else
      tasks = if kept == [], do: "", else: Spec.render_blocks(preamble, kept)
      write(spec, %{tasks: tasks}, "Removed.")
    end
  end

  defp questions(args) do
    for q <- List.wrap(args["questions"]),
        is_map(q),
        question = text(q["question"]),
        question != "" do
      %{"question" => question, "options" => q["options"] |> lines() |> Enum.take(4)}
    end
    |> Enum.take(5)
  end

  # The queue follows the tasks: a renamed one (`renames`, old title => new) keeps its
  # place, and removed ones leave it (`Factory.Specs.follow_tasks/2`).
  defp write(spec, attrs, done, renames \\ %{}) do
    with {:ok, spec} <- Specs.update_spec(spec, attrs),
         {:ok, spec} <- Specs.follow_tasks(spec, renames) do
      {:ok, {:changed, done <> " " <> describe(spec)}}
    else
      {:error, _} -> {:error, "Factory couldn't save that change."}
    end
  end

  @doc """
  The plan in `spec` as the planner sees it: its approach, then its numbered tasks, by
  title, or `:full` with their details as the spec has them.
  """
  def describe(spec, detail \\ :titles) do
    tasks =
      case {checklist(spec.tasks), detail} do
        {{_, []}, _} ->
          "The plan has no tasks yet."

        {{_, blocks}, :titles} ->
          "The plan's tasks:\n" <>
            (blocks
             |> Enum.with_index(1)
             |> Enum.map_join("\n", fn {b, i} -> "#{i}. #{b.title}" end))

        {{preamble, blocks}, :full} ->
          "The plan's tasks:\n" <> String.trim(Spec.render_blocks(preamble, blocks))
      end

    if planner_design?(spec.design) and String.trim(spec.design || "") != "",
      do: String.trim(spec.design) <> "\n\n" <> tasks,
      else: tasks
  end

  # The tasks as checklist blocks. A plain numbered list (from an attached tasks.md) is
  # turned into a checklist first, so tasks added to it are read back as tasks; every
  # part of each task goes with it.
  defp checklist(markdown) do
    {preamble, blocks} = Spec.blocks(markdown || "")

    if blocks == [] or Regex.match?(~r/^[-*] \[[ xX]\]/m, markdown) do
      {preamble, blocks}
    else
      {preamble,
       Enum.map(blocks, fn b ->
         task_block(
           Planner.task(%{
             "title" => b.title,
             "objective" => b.objective,
             "details" => b.details,
             "verify" => b.verify,
             "agent" => b.agent,
             "model" => b.model,
             "requirements" => b.requirements
           })
         )
       end)}
    end
  end

  # A task in the one shape (`Factory.Specs.Planner.task/1`) as a checklist block.
  defp task_block(task) do
    {_, [block]} = Spec.blocks(Planner.to_markdown([task], 1))
    block
  end

  defp planner_design?(design) do
    design = String.trim(design || "")
    design == "" or String.starts_with?(design, @approach)
  end

  defp lines(list) do
    for item <- List.wrap(list),
        is_binary(item) or is_number(item),
        line <- item |> to_string() |> String.split(~r/\R/u),
        line = String.trim(line),
        line != "",
        do: line
  end

  # A model the planner gave a task: one Factory may pick, else auto (never Sonnet).
  defp task_model(model), do: if(model in Factory.Kiro.task_models(), do: model, else: "auto")

  defp finish(text), do: String.trim(text) <> "\n"
end
