defmodule Factory.RunTools do
  @moduledoc """
  Tools an agent on Kiro uses while it works on a run step: it reads the run's tasks
  and marks them done as it finishes them, so the run's progress is real rather than
  set all at once at the end. Kiro reaches them over MCP (`FactoryWeb.MCP`), like the
  planner's tools (`Factory.PlanTools`), on the same server under another token.

  Each step gets a token (`grant/2`) naming its run and step. A call only writes while
  the run is on that step (`progress["current"]`) and hasn't been cancelled or
  finished, so a step that was replaced or a run that moved on can't change the tasks.
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
    }
  ]

  @doc "The tools, as MCP `tools/list` gives them."
  def tools, do: @tools

  @doc "A token for one step of a run: calls with it act on run `run_id` while it's on `step_id`."
  def grant(run_id, step_id),
    do: Phoenix.Token.sign(FactoryWeb.Endpoint, @salt, %{run_id: run_id, step_id: step_id})

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
         true <- Enum.any?(@tools, &(&1.name == name)) || {:error, "There's no tool #{name}."} do
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
