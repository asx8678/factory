defmodule Factory.WorkflowsTest do
  use Factory.DataCase, async: true
  alias Factory.{Agents, Chat, Runs, Workflows}
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
end
