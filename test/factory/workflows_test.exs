defmodule Factory.WorkflowsTest do
  use Factory.DataCase, async: true
  alias Factory.{Agents, Chat, Runs, Sources, Workflows}
  alias Factory.Runs.Types

  test "the standard workflows match the jobs on the start screen" do
    workflows = Workflows.list()
    assert Enum.map(Enum.filter(workflows, & &1.key), & &1.key) == ~w(feature bug issue deps)

    bug = Workflows.standard("bug")
    assert bug.name == "Fix a bug"
    assert Enum.map(Workflows.steps(bug), & &1["name"]) == ~w(Investigator Fixer Tester Reviewer)
    refute Workflows.modified?(bug)

    # Each agent hands off to the next and has a starting prompt.
    [first | _] = agents = Workflows.ordered_agents(bug.id)
    assert first.prompt =~ "Investigator"
    assert length(Agents.graph(bug.id).edges) == length(agents) - 1

    # "Other" has no standard workflow; it keeps its built-in default.
    assert Workflows.standard("other") == nil
    assert [_ | _] = Types.workflow("other")
  end

  test "a standard workflow can be changed, and restored to its default" do
    bug = Workflows.standard("bug")
    [investigator | _] = Workflows.ordered_agents(bug.id)
    {:ok, _} = Agents.update_agent(investigator, %{name: "Detective"})

    assert Workflows.modified?(bug)
    assert ["Detective" | _] = Enum.map(Workflows.steps(bug), & &1["name"])

    {:ok, bug} = Workflows.restore(bug)
    refute Workflows.modified?(bug)
    assert ["Investigator" | _] = Enum.map(Workflows.steps(bug), & &1["name"])

    # A new arrow counts as a change too.
    [a, _, c | _] = Workflows.ordered_agents(bug.id)
    {:ok, _} = Agents.link(a.id, c.id)
    assert Workflows.modified?(bug)
  end

  test "a workflow can be cloned, renamed and deleted; standard ones can't be deleted" do
    feature = Workflows.standard("feature")
    {:ok, copy} = Workflows.clone(feature)
    assert copy.name == "Build a feature (copy)"
    assert copy.key == nil

    assert Enum.map(Workflows.steps(copy), & &1["name"]) ==
             Enum.map(Workflows.steps(feature), & &1["name"])

    assert length(Agents.graph(copy.id).edges) == 3

    # The copy is separate: changing it leaves the original alone.
    [planner | _] = Workflows.ordered_agents(copy.id)
    {:ok, _} = Agents.update_agent(planner, %{name: "Architect"})
    refute Workflows.modified?(feature)

    {:ok, second} = Workflows.clone(feature)
    assert second.name == "Build a feature (copy) 2"

    {:ok, copy} = Workflows.rename(copy, "My feature flow")
    assert copy.name == "My feature flow"

    assert {:error, :standard} = Workflows.delete(feature)
    {:ok, _} = Workflows.delete(copy)
    assert Workflows.get(copy.id) == nil
    assert Agents.get_agent(planner.id) == nil
  end

  test "plain chats talk to the current workflow; a run to its own" do
    {:ok, mine} = Workflows.create("Mine")
    {:ok, mine} = Workflows.set_current(mine)
    {:ok, _} = Agents.create_agent(%{name: "Solo"})
    assert [%{name: "Solo"}] = Agents.list_agents(mine.id)

    {:ok, run} = Runs.create_run()
    Runs.subscribe(run.id)
    Chat.handle(run, "/workflow")
    assert_receive {:message, %{body: "Agents in Mine:\n• Solo: auto, vibe mode"}}

    # A run started with the bug workflow sees its agents instead.
    {:ok, run} =
      Runs.update_run(run, %{settings: %{"workflow_id" => Workflows.standard("bug").id}})

    assert Workflows.for_run(run).key == "bug"
    Chat.handle(run, "/ask Solo hi")
    assert_receive {:message, %{body: "Name the agent first" <> _}}
  end

  test "an explicit missing workflow never falls back to the current workflow" do
    {:ok, current} = Workflows.create("Current")
    {:ok, _} = Workflows.set_current(current)
    {:ok, missing} = Workflows.create("Missing")
    {:ok, _} = Workflows.delete(missing)

    assert Workflows.for_run(%{settings: %{"workflow_id" => missing.id}}) == nil
    assert Workflows.for_run(%{settings: %{}}).id == current.id
  end

  test "custom workflows referenced by unfinished runs cannot be deleted" do
    {:ok, workflow} = Workflows.create("Still needed")
    {:ok, agent} = Agents.create_agent(%{name: "Coder", workflow_id: workflow.id})
    {:ok, run} = Runs.create_run()
    {:ok, run} = Runs.update_run(run, %{settings: %{"workflow_id" => workflow.id}})

    for status <- ~w(draft queued running paused) do
      {:ok, _} = Runs.update_run(Runs.get_run(run.id), %{status: status})
      assert {:error, :in_use} = Workflows.delete(workflow)
      assert Workflows.get(workflow.id)
      assert Agents.get_agent(agent.id)
    end

    {:ok, _} = Runs.update_run(Runs.get_run(run.id), %{status: "done"})
    assert {:ok, _} = Workflows.delete(workflow)
  end

  test "cancelled runs do not prevent deleting their workflow" do
    {:ok, workflow} = Workflows.create("Finished")
    {:ok, run} = Runs.create_run()

    {:ok, _} =
      Runs.update_run(run, %{status: "cancelled", settings: %{"workflow_id" => workflow.id}})

    assert {:ok, _} = Workflows.delete(workflow)
  end

  test "selecting an already current workflow preserves the single current row" do
    {:ok, first} = Workflows.create("First choice")
    {:ok, second} = Workflows.create("Second choice")
    {:ok, _} = Workflows.set_current(first)
    {:ok, first} = Workflows.set_current(first)
    assert first.current
    assert Workflows.get(first.id).current
    {:ok, _} = Workflows.set_current(second)

    assert [second.id] ==
             Repo.all(from w in Factory.Agents.Workflow, where: w.current, select: w.id)
  end

  test "a clone keeps sources and attachments on the copied agents" do
    {:ok, workflow} = Workflows.create("Sources to copy")
    {:ok, agent} = Agents.create_agent(%{name: "Reader", workflow_id: workflow.id})

    {:ok, source} =
      Sources.create(workflow.id, %{kind: "instructions", name: "Rules", content: "Be precise."})

    {:ok, _} = Sources.attach(source, agent.id)

    {:ok, copy} = Workflows.clone(workflow)
    assert [copied_source] = Sources.list(copy.id)
    assert [copied_agent] = Agents.list_agents(copy.id)
    assert copied_source.content == source.content
    assert Sources.agent_ids(copied_source) == [copied_agent.id]
    assert Sources.agent_ids(source) == [agent.id]
  end

  test "a failed clone rolls back without broadcasting partial records" do
    {:ok, workflow} = Workflows.create("Cannot copy")
    {:ok, _} = Agents.create_agent(%{name: "Reader", workflow_id: workflow.id})
    # A source whose required configuration was lost cannot be copied successfully.
    Repo.insert!(%Sources.Source{
      workflow_id: workflow.id,
      kind: "git",
      name: "Invalid",
      config: %{}
    })

    Agents.subscribe()
    parent = self()

    worker =
      start_supervised!(
        {Task,
         fn ->
           receive do
             :clone -> send(parent, {:cloned, Workflows.clone(workflow, "Rolled back")})
           end
         end}
      )

    ref = Process.monitor(worker)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), worker)
    send(worker, :clone)
    assert_receive {:cloned, {:error, %Ecto.Changeset{}}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
    # (No broadcast check: other async tests share the global graph topic.)
    refute Repo.exists?(from w in Factory.Agents.Workflow, where: w.name == "Rolled back")
  end
end
