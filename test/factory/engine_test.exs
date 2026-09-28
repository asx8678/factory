defmodule Factory.EngineTest do
  # Not async: steps talk to the fake kiro-cli.
  use Factory.DataCase, async: false
  alias Factory.{Agents, Chat, Engine, Runs, Sources, Workflows}

  # Planner → Coder → Tester → "Run a command", with the Tester drawn above the Coder
  # so reading order and the arrows disagree; a rules file is attached to the Coder.
  defp workflow(command) do
    {:ok, w} = Workflows.create("Ship it")

    card = fn name, kind, x, y ->
      {:ok, a} = Agents.create_agent(%{name: name, kind: kind, x: x, y: y, workflow_id: w.id})
      a
    end

    tester = card.("Tester", "tester", 400.0, 0.0)
    planner = card.("Planner", "planner", 0.0, 100.0)
    coder = card.("Coder", "coder", 200.0, 200.0)
    {:ok, _} = Agents.link(planner.id, coder.id)
    {:ok, _} = Agents.link(coder.id, tester.id)

    {:ok, action} = Agents.add_action(w.id, "command", 600.0, 300.0, from: tester.id)

    {:ok, _} =
      Agents.update_agent(action, %{
        action: %{"type" => "command", "config" => %{"command" => command}}
      })

    {:ok, rules} =
      Sources.create(w.id, %{
        kind: "instructions",
        name: "Rules",
        content: "Use British spelling."
      })

    {:ok, _} = Sources.attach(rules, coder.id)
    %{w: w, planner: planner, coder: coder, tester: tester, action: action}
  end

  defp queued_run(w) do
    {:ok, run} = Runs.create_run("Add dark mode")

    {:ok, run} =
      Runs.update_run(run, %{
        status: "queued",
        kind: "feature",
        description: "Add a dark mode toggle.",
        spec: "<!-- file: tasks.md -->\n- [ ] 1. Add the toggle",
        settings: %{"workflow_mode" => "recommended", "workflow_id" => w.id}
      })

    run
  end

  test "steps follow the arrows, not where cards are drawn" do
    %{w: w} = workflow("true")
    names = Enum.map(Engine.steps(queued_run(w)), & &1.name)
    assert names == ["Planner", "Coder", "Tester", "Run a command"]
  end

  test "each agent gets its sources and what came before; actions run in their place" do
    %{w: w, coder: coder, tester: tester} = workflow("echo shipped")
    run = queued_run(w)
    Runs.subscribe(run.id)

    assert {:ok, run} = Engine.run(run.id)
    assert run.status == "done"

    outputs = run.progress["outputs"]
    planner_out = outputs["agent-#{Enum.at(Engine.steps(run), 0).agent.id}"]
    coder_out = outputs["agent-#{coder.id}"]
    tester_out = outputs["agent-#{tester.id}"]

    # The fake Kiro echoes its prompt, so each reply shows what the agent was given.
    assert planner_out =~ "Add a dark mode toggle."
    assert planner_out =~ "Add the toggle"
    assert planner_out =~ "Don't change any files"
    refute planner_out =~ "British"

    assert coder_out =~ "Use British spelling."
    assert coder_out =~ ~s(<handoff from="Planner">)
    # Sources go only to the agent they're attached to (outside what it was handed).
    refute tester_out |> String.split("</handoff>") |> List.last() =~ "British"
    assert tester_out =~ ~s(<handoff from="Coder">)

    # The command ran after the Tester, with the Tester's hand-off as its summary.
    assert Enum.find_value(outputs, fn {_, text} -> text =~ "shipped" && text end)
    assert_received {:message, %{author: "Run a command"}}
    assert Agents.get_agent(coder.id).status == "done"
  end

  test "a failing step pauses the run there, and resuming picks up from it" do
    %{w: w, action: action} = workflow("exit 3")
    run = queued_run(w)

    assert {:error, _} = Engine.run(run.id)
    run = Runs.get_run(run.id)
    assert run.status == "paused"
    assert run.progress["current"] == "agent-#{action.id}"
    assert length(run.progress["done"]) == 3

    {:ok, _} =
      Agents.update_agent(action, %{
        action: %{"type" => "command", "config" => %{"command" => "true"}}
      })

    {:ok, _} = Runs.update_run(run, %{status: "queued"})
    Runs.subscribe(run.id)
    assert {:ok, %{status: "done"}} = Engine.run(run.id)
    # Only the action ran again, not the agents.
    refute_received {:message, %{author: "Planner"}}
  end

  test "an arrow back is a loop: the work goes again with the feedback, then on" do
    %{w: w, coder: coder, tester: tester} = workflow("true")
    # The Tester can send the work back to the Coder.
    {:ok, _} = Agents.link(tester.id, coder.id)
    {:ok, _} = Agents.update_agent(tester, %{prompt: "[test:send-back]"})

    steps = Engine.steps(queued_run(w))
    assert Enum.map(steps, & &1.name) == ["Planner", "Coder", "Tester", "Run a command"]
    assert Enum.find(steps, &(&1.name == "Tester")).loops == ["agent-#{coder.id}"]
    assert Enum.find(steps, &(&1.name == "Coder")).after == [Enum.at(steps, 0).id]

    run = queued_run(w)
    Runs.subscribe(run.id)
    assert {:ok, %{status: "done"} = run} = Engine.run(run.id)

    assert_received {:message,
                     %{body: "Tester sent it back to Coder (pass 1 of 2): add the missing test"}}

    assert run.progress["rounds"] == %{"agent-#{tester.id}" => 1}
    # The Coder's second pass had the feedback; the Tester then approved.
    assert run.progress["outputs"]["agent-#{coder.id}"] =~
             ~s(<feedback from="Tester">\nadd the missing test\n</feedback>)

    assert run.progress["outputs"]["agent-#{tester.id}"] =~ "Approved"
  end

  test "a reply's last line says whether to send the work back" do
    assert Engine.verdict("Looks good.\nApproved") == nil

    assert Engine.verdict("Two issues.\n\nSend back: fix the date parsing.\n") ==
             "fix the date parsing"

    assert Engine.verdict("**Send back**") == "**Send back**"
    assert Engine.verdict("Don't send back anything.\nApproved") == nil
  end

  test "an arrow's prompt goes to the agent it points to, only on that hand-off" do
    %{w: w, planner: planner, coder: coder, tester: tester} = workflow("true")

    link =
      Enum.find(Workflows.links(w.id), &(&1.source_id == planner.id and &1.target_id == coder.id))

    {:ok, _} = Agents.set_link_prompt(link, "Start with the smallest task.")

    assert {:ok, run} = Engine.run(queued_run(w).id)
    coder_out = run.progress["outputs"]["agent-#{coder.id}"]
    tester_out = run.progress["outputs"]["agent-#{tester.id}"]

    assert coder_out =~
             ~s(<handoff-instructions from="Planner">\nStart with the smallest task.\n</handoff-instructions>)

    refute tester_out |> String.split("</handoff>") |> List.last() =~ "smallest task"
  end

  test "an arrow keeps its prompt when an end is moved" do
    %{w: w, planner: planner, coder: coder, tester: tester} = workflow("true")

    link =
      Enum.find(Workflows.links(w.id), &(&1.source_id == planner.id and &1.target_id == coder.id))

    {:ok, _} = Agents.set_link_prompt(link, "Be brief.")

    {:ok, _} = Agents.relink({planner.id, coder.id}, {planner.id, tester.id})

    assert Enum.find(
             Workflows.links(w.id),
             &(&1.target_id == tester.id and &1.source_id == planner.id)
           ).prompt == "Be brief."
  end

  test "a step's prompt stays within the budget, and its size and hash are kept" do
    %{w: w, coder: coder, planner: planner} = workflow("true")
    Application.put_env(:factory, :context, run_prompt_bytes: 3000)
    on_exit(fn -> Application.delete_env(:factory, :context) end)

    run = queued_run(w)
    huge = String.duplicate("A long plan line.\n", 1000)

    {:ok, run} =
      Runs.update_run(run, %{
        progress: %{
          "done" => ["agent-#{planner.id}"],
          "outputs" => %{"agent-#{planner.id}" => huge}
        }
      })

    steps = Engine.steps(run)
    step = Enum.find(steps, &(&1.id == "agent-#{coder.id}"))
    prompt = Engine.prompt(run, steps, step)

    assert byte_size(prompt) <= 3000
    # The hand-off is shortened; the job, spec and sources stay whole.
    assert prompt =~
             ~r/<handoff from="Planner">\nA long plan line\.\n.*\n\[omitted \d+ UTF-8 bytes\]\n<\/handoff>/s

    assert prompt =~ "<job>\nAdd a dark mode toggle.\n</job>"
    assert prompt =~ "<spec>\n<!-- file: tasks.md -->\n- [ ] 1. Add the toggle\n</spec>"
    assert prompt =~ "Use British spelling."
    assert prompt =~ "When you're done, reply with a short summary"
    assert prompt == Engine.prompt(run, steps, step)

    assert {:ok, run} = Engine.run(run.id)
    sent = run.progress["prompts"]["agent-#{coder.id}"]
    assert sent["bytes"] <= 3000
    assert sent["omitted_bytes"] > 0
    assert sent["sha256"] =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "an empty workflow pauses without completing any tasks" do
    {:ok, workflow} = Workflows.create("Empty workflow")
    run = workflow |> queued_run() |> with_task()

    assert {:error, reason} = Engine.run(run.id)
    assert reason =~ "no steps"
    assert %{status: "paused", tasks: [%{status: "pending"}]} = Runs.get_run(run.id)
    refute Enum.any?(Runs.list_messages(run.id), &String.starts_with?(&1.body, "Done:"))
  end

  test "a missing explicit workflow pauses instead of using the current workflow" do
    %{w: current} = workflow("true")
    {:ok, _} = Workflows.set_current(current)
    {:ok, missing} = Workflows.create("Deleted workflow")
    {:ok, _} = Workflows.delete(missing)
    run = missing |> queued_run() |> with_task()

    assert {:error, reason} = Engine.run(run.id)
    assert reason =~ "no longer exists"
    assert %{status: "paused", tasks: [%{status: "pending"}]} = Runs.get_run(run.id)
  end

  test "one worker owns a run until its in-flight step exits, including after pause" do
    run = action_run()
    parent = self()

    Req.Test.stub(Factory.Actions, fn conn ->
      send(parent, {:step_started, self()})

      receive do
        :finish_step -> Plug.Conn.send_resp(conn, 200, "done")
      end
    end)

    worker =
      start_supervised!(
        {Task,
         fn ->
           receive do
             :start -> send(parent, {:finished, Engine.run(run.id)})
           end
         end}
      )

    ref = Process.monitor(worker)
    Req.Test.allow(Factory.Actions, self(), worker)
    send(worker, :start)
    assert_receive {:step_started, ^worker}, 5_000
    assert Engine.running?(run.id)
    assert {:error, :already_running} = Engine.run(run.id)
    assert {:error, :already_running} = Engine.run(to_string(run.id))

    Chat.handle(Runs.get_run(run.id), "/pause")
    Chat.handle(Runs.get_run(run.id), "/resume")
    assert %{status: "paused"} = Runs.get_run(run.id)
    assert List.last(Runs.list_messages(run.id)).body =~ "still finishing"

    send(worker, :finish_step)
    assert_receive {:finished, {:ok, %{status: "paused"}}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
    refute Engine.running?(run.id)
    assert [%{status: "pending"}] = Runs.get_run(run.id).tasks
  end

  for response_status <- [200, 400] do
    test "cancelling during the final step survives HTTP #{response_status}" do
      run = action_run()

      Req.Test.stub(Factory.Actions, fn conn ->
        {:ok, _} = Runs.update_run(Runs.get_run(run.id), %{status: "cancelled"})
        Plug.Conn.send_resp(conn, unquote(response_status), "finished after cancellation")
      end)

      Engine.run(run.id)
      assert %{status: "cancelled", tasks: [%{status: "pending"}]} = Runs.get_run(run.id)

      refute Enum.any?(Runs.list_messages(run.id), fn message ->
               String.starts_with?(message.body, "Done:") or message.body =~ "The run is paused"
             end)

      refute Engine.running?(run.id)
    end
  end

  defp with_task(run) do
    {:ok, run} =
      Runs.attach_spec(run, [{"tasks.md", "- [ ] 1. Ship it"}], [%{ref: "1", title: "Ship it"}])

    run
  end

  defp action_run do
    {:ok, workflow} = Workflows.create("One action")
    {:ok, action} = Agents.add_action(workflow.id, "api_request", 0.0, 0.0)

    {:ok, _} =
      Agents.update_agent(action, %{
        action: %{
          "type" => "api_request",
          "config" => %{"url" => "https://example.test/step", "method" => "get"}
        }
      })

    workflow |> queued_run() |> with_task()
  end
end
