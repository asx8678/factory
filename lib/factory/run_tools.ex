defmodule Factory.RunTools do
  @moduledoc """
  Tools an agent on Kiro uses while it works on a run step. Kiro reaches them over MCP
  (`FactoryWeb.MCP`), like the planner's tools (`Factory.PlanTools`), on the same
  server under another token.

    * `get_tasks` and `complete_tasks`, for steps that change the project: the agent
      marks tasks done as it finishes them, so the run's progress is real rather than
      set all at once at the end.
    * `verdict`, for a step with an arrow back (`Factory.Engine`): approve the work, or
      send it back with what to fix. It's kept in `progress["verdicts"]`; a reply
      ending in "Approved" or "Send back: …" still works without it.

  Each step gets a token (`grant/3`) naming its run, its step and which tools it has.
  A call only writes while the run is on that step (`progress["current"]`) and hasn't
  been cancelled or finished, so a step that was replaced or a run that moved on
  can't change anything.
  """
  alias Factory.Runs

  @salt "factory run tools"

  @tools [
    %{
      name: "get_tasks",
      description: "The run's tasks, numbered as the spec numbers them, and which are done.",
      inputSchema: %{type: "object", properties: %{}}
    },
    %{
      name: "complete_tasks",
      description:
        "Marks tasks done by their numbers, e.g. [1, 2] or [\"1.2\"]. Call it as you finish " <>
          "each task, only for work that is built and checked.",
      inputSchema: %{
        type: "object",
        properties: %{
          numbers: %{
            type: "array",
            minItems: 1,
            items: %{type: ["integer", "string"]},
            description: "The task numbers, as get_tasks shows them."
          }
        },
        required: ["numbers"]
      }
    },
    %{
      name: "verdict",
      description:
        "Says whether the work is good. \"approved\" lets the run go on; \"send_back\" " <>
          "has it done again, with `fix` saying what to change. Call it once, at the end.",
      inputSchema: %{
        type: "object",
        properties: %{
          decision: %{type: "string", enum: ["approved", "send_back"]},
          fix: %{type: "string", description: "What to fix, for send_back."}
        },
        required: ["decision"]
      }
    }
  ]

  @task_tools ~w(get_tasks complete_tasks)

  @doc "Every run tool, as MCP `tools/list` gives them."
  def tools, do: @tools

  @doc "The tools the step `token` was granted to has."
  def tools(token) do
    case verify(token) do
      {:ok, grant} -> Enum.filter(@tools, &allowed?(grant, &1.name))
      _ -> []
    end
  end

  defp allowed?(grant, name) when name in @task_tools, do: Map.get(grant, :tasks, true)
  defp allowed?(grant, "verdict"), do: Map.get(grant, :verdict, false)

  @doc """
  A token for one step of a run: calls with it act on run `run_id` while it's on
  `step_id`. Options say which tools it has: `tasks:` (default true) and `verdict:`.
  """
  def grant(run_id, step_id, opts \\ []) do
    Phoenix.Token.sign(FactoryWeb.Endpoint, @salt, %{
      run_id: run_id,
      step_id: step_id,
      tasks: Keyword.get(opts, :tasks, true),
      verdict: Keyword.get(opts, :verdict, false)
    })
  end

  @doc "The MCP server to give Kiro for a step: Factory's, with the step's token."
  def mcp_server(token), do: Factory.PlanTools.mcp_server(token)

  @doc "Whether `token` was granted for a run step (else it's a planner's, or none)."
  def token?(token), do: match?({:ok, _}, verify(token))

  defp verify(token),
    do: Phoenix.Token.verify(FactoryWeb.Endpoint, @salt, token || "", max_age: 86_400)

  @doc """
  Runs tool `name` with `args` for the step `token` was granted to: `{:ok, text}` for
  Kiro, or `{:error, text}` saying what to do instead.
  """
  def call(token, name, args) when is_map(args) do
    with {:ok, grant} <- verify(token) |> or_error("Factory didn't recognise this step."),
         true <-
           (Enum.any?(@tools, &(&1.name == name)) and allowed?(grant, name)) ||
             {:error, "There's no tool #{name}."} do
      result =
        Runs.with_locked_run(grant.run_id, fn run ->
          if run.status in ["running", "paused"] and run.progress["current"] == grant.step_id,
            do: apply_tool(name, args, run),
            else: {:error, "This step is over: the run moved on. End your turn."}
        end)

      case result do
        {:ok, {:changed, run, text}} ->
          Runs.tasks_changed(run)
          {:ok, text}

        {:ok, {:read, text}} ->
          {:ok, text}

        {:error, text} when is_binary(text) ->
          {:error, text}

        {:error, _} ->
          {:error, "This run no longer exists. End your turn."}
      end
    end
  end

  def call(_token, _name, _args), do: {:error, "The arguments must be an object."}

  defp or_error({:ok, _} = ok, _text), do: ok
  defp or_error(_error, text), do: {:error, text <> " End your turn."}

  defp apply_tool("get_tasks", _args, run), do: {:ok, {:read, describe(run.tasks)}}

  defp apply_tool("verdict", args, run) do
    fix = if is_binary(args["fix"]), do: String.trim(args["fix"]), else: ""

    verdict =
      case args["decision"] do
        "approved" -> {:ok, %{"decision" => "approved"}}
        "send_back" when fix != "" -> {:ok, %{"decision" => "send_back", "fix" => fix}}
        "send_back" -> {:error, "Say what to fix in `fix`."}
        _ -> {:error, ~s(The decision is "approved" or "send_back".)}
      end

    with {:ok, verdict} <- verdict do
      step = run.progress["current"]
      progress = put_in(run.progress, [Access.key("verdicts", %{}), step], verdict)
      {:ok, run} = Runs.update_run(run, %{progress: progress})
      {:ok, {:changed, run, "Noted. End your turn with a short summary."}}
    end
  end

  defp apply_tool("complete_tasks", args, run) do
    wanted = for n <- List.wrap(args["numbers"]), n = number(n), n != nil, do: n
    {found, missing} = Enum.split_with(wanted, &find(run.tasks, &1))
    tasks = Enum.map(found, &find(run.tasks, &1))

    cond do
      wanted == [] ->
        {:error, "Give the numbers of the tasks you finished."}

      found == [] ->
        {:error, "There's no task #{Enum.join(missing, ", ")}. #{describe(run.tasks)}"}

      true ->
        run = Runs.mark_tasks_done(run, Enum.map(tasks, & &1.id))
        not_found = if missing == [], do: "", else: " No task #{Enum.join(missing, ", ")}."
        {:ok, {:changed, run, "Marked done.#{not_found} #{describe(run.tasks)}"}}
    end
  end

  # A task's number as the spec shows it ("2", "1.3"), else its place in the list.
  defp find(tasks, number),
    do: Enum.find(tasks, &(&1.ref == number or (&1.ref == nil and "#{&1.position}" == number)))

  defp number(n) when is_integer(n), do: Integer.to_string(n)

  defp number(n) when is_binary(n) do
    case n |> String.trim() |> String.trim_trailing(".") do
      "" -> nil
      n -> n
    end
  end

  defp number(_), do: nil

  @doc "The tasks as an agent sees them: number, title and whether each is done."
  def describe([]), do: "The run has no tasks."

  def describe(tasks) do
    done = Enum.count(tasks, &(&1.status == "done"))

    "Tasks (#{done} of #{length(tasks)} done):\n" <>
      Enum.map_join(tasks, "\n", fn t ->
        "#{t.ref || t.position}. [#{if t.status == "done", do: "x", else: " "}] #{t.title}"
      end)
  end
end
