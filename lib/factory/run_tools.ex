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

  A token says which step a call is for. A run step on its agent's Kiro session
  (`Factory.Kiro.run_step/4`) is reached through the session's token
  (`grant_session/2`): the session knows the step it's answering, and outside one (a
  chat message) the tools refuse. `grant/3` names a run and step directly. Either way
  a call only writes while the run is on that step (`progress["current"]`) and hasn't
  been cancelled or finished, so a step that was replaced or a run that moved on
  can't change anything.

  A session's token carries a random value the session chose when it started
  (`Factory.Kiro.Session.token_nonce/1`); it's only good while that very session runs,
  so a token that leaked from a finished session opens nothing. It also expires after
  a week, a step's after a day.
  """
  alias Factory.Runs

  @salt "factory run tools"
  @session_max_age 7 * 86_400
  @step_max_age 86_400

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

  @doc """
  The tools `token` offers. A session's lists them all, as Kiro reads them once when
  the session starts; each call is checked against the step then (`call/3`).
  """
  def tools(token) do
    case verify(token) do
      {:ok, %{session: key}} -> @tools ++ plan_tools(key)
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

  # A session whose agent can plan (a planner, researcher or orchestrator, or the
  # shared one) also has the planner's tools, for chat messages (`Factory.PlanTools`).
  @planning ~w(planner researcher orchestrator)

  defp plan_tools(:shared), do: Factory.PlanTools.tools()

  defp plan_tools(agent_id) do
    case Factory.Agents.get_agent(agent_id) do
      %{kind: kind} when kind in @planning -> Factory.PlanTools.tools()
      _ -> []
    end
  end

  defp plan_tool?(name), do: Enum.any?(Factory.PlanTools.tools(), &(&1.name == name))

  @doc """
  A token for a Kiro session (`:shared` or an agent id): calls act on the step it's
  answering. `nonce` is the session's (`Factory.Kiro.Session.token_nonce/1`); given the
  key alone, it's asked of the running session, and a token for a session that isn't
  running is refused.
  """
  def grant_session(key, nonce \\ nil) do
    nonce = nonce || session_nonce(key)
    Phoenix.Token.sign(FactoryWeb.Endpoint, @salt, %{session: key, nonce: nonce})
  end

  # The nonce of the session `key` names, or nil when none runs.
  defp session_nonce(key) do
    case Factory.Kiro.whereis(key) do
      pid when is_pid(pid) -> Factory.Kiro.Session.token_nonce(pid)
      nil -> nil
    end
  catch
    :exit, _ -> nil
  end

  @doc "The MCP server to give Kiro for a step: Factory's, with the step's token."
  def mcp_server(token), do: Factory.PlanTools.mcp_server(token)

  @doc "Whether `token` was granted for a run step (else it's a planner's, or none)."
  def token?(token), do: match?({:ok, _}, verify(token))

  # A step's token is used within the step, so a day is plenty. A session's token lives
  # as long as the session (it's minted when the session starts, which may be days
  # ago), so it has a week; what gates it is that the session that minted it (its
  # nonce says which) still runs, and that it's on a step (`resolve/1`).
  defp verify(token) do
    token = token || ""

    case Phoenix.Token.verify(FactoryWeb.Endpoint, @salt, token, max_age: @session_max_age) do
      {:ok, %{session: key, nonce: nonce}} = ok when is_binary(nonce) ->
        case session_nonce(key) do
          current when is_binary(current) ->
            if Plug.Crypto.secure_compare(current, nonce), do: ok, else: {:error, :invalid}

          nil ->
            {:error, :invalid}
        end

      {:ok, %{session: _}} ->
        {:error, :invalid}

      {:ok, _step} ->
        Phoenix.Token.verify(FactoryWeb.Endpoint, @salt, token, max_age: @step_max_age)

      error ->
        error
    end
  end

  @doc """
  Runs tool `name` with `args` for the step `token` was granted to: `{:ok, text}` for
  Kiro, or `{:error, text}` saying what to do instead.
  """
  def call(token, name, args) when is_map(args) do
    case verify(token) do
      {:ok, %{session: key}} ->
        cond do
          plan_tool?(name) -> plan_in_session(key, name, args)
          name == "get_tasks" -> tasks_in_session(key, token)
          true -> call_step(token, name, args)
        end

      _ ->
        call_step(token, name, args)
    end
  end

  def call(_token, _name, _args), do: {:error, "The arguments must be an object."}

  # A planner's tool from a session: for the chat message it's answering, not a run step.
  defp plan_in_session(key, name, args) do
    with pid when is_pid(pid) <- Factory.Kiro.whereis(key),
         %{run_id: run_id, agent: agent, step: nil} = turn <-
           Factory.Kiro.Session.current_turn(pid) do
      Factory.PlanTools.call_in_turn(run_id, agent, name, args, turn[:planning])
    else
      %{step: %{}} -> {:error, "During a run step, work on the tasks as they are."}
      _ -> {:error, "These tools only work while you're answering a message."}
    end
  catch
    :exit, _ -> {:error, "These tools only work while you're answering a message."}
  end

  # Reading the tasks is fine in a chat message too; in a run step it's the step's.
  defp tasks_in_session(key, token) do
    with pid when is_pid(pid) <- Factory.Kiro.whereis(key),
         %{run_id: run_id, step: nil} <- Factory.Kiro.Session.current_turn(pid),
         %{} = run <- Runs.get_run(run_id) do
      {:ok, describe(run.tasks)}
    else
      %{step: %{}} -> call_step(token, "get_tasks", %{})
      _ -> {:error, "These tools only work while you're answering a message."}
    end
  catch
    :exit, _ -> {:error, "These tools only work while you're answering a message."}
  end

  defp call_step(token, name, args) do
    with {:ok, grant} <- verify(token) |> or_error("Factory didn't recognise this step."),
         {:ok, grant} <- resolve(grant),
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

  # A session's token stands for the step the session is answering right now.
  defp resolve(%{session: key}) do
    with pid when is_pid(pid) <- Factory.Kiro.whereis(key),
         %{run_id: run_id, step: step} <- Factory.Kiro.Session.current_step(pid) do
      {:ok, %{run_id: run_id, step_id: step.id, tasks: step.tasks, verdict: step.verdict}}
    else
      _ ->
        {:error,
         "These tools only work on a step of a factory run. To change a run's plan from " <>
           "the chat, use get_plan, add_tasks, update_task and remove_tasks."}
    end
  catch
    :exit, _ -> {:error, "These tools only work while you're on a step of a factory run."}
  end

  defp resolve(grant), do: {:ok, grant}

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
