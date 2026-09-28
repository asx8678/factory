defmodule Factory.PlanningTest do
  # Not async: the planner asks the fake kiro-cli from a background task.
  use Factory.DataCase, async: false
  alias Factory.{Agents, Chat, Runs, Specs, Workflows}

  # A chat on a workflow with a Planner and a Coder, in a real folder.
  setup do
    {:ok, w} = Workflows.create("Plan it")
    {:ok, planner} = Agents.create_agent(%{name: "Planner", kind: "planner", workflow_id: w.id})

    {:ok, coder} =
      Agents.create_agent(%{name: "Coder", kind: "coder", workflow_id: w.id, y: 100.0})

    {:ok, _} = Agents.link(planner.id, coder.id)

    {:ok, run} = Runs.create_run()

    {:ok, run} =
      Runs.update_run(run, %{settings: %{"workflow_id" => w.id, "project_dir" => File.cwd!()}})

    Runs.subscribe(run.id)
    %{run: run, planner: planner}
  end

  defp plan(run, planner, text, files \\ []) do
    Chat.handle(Runs.get_run(run.id), text, files, to: planner)
    assert_receive {:message, %{author: "Planner"} = reply}, 5_000
    {reply, Runs.get_run(run.id)}
  end

  test "writing to the planner plans the run's tasks and offers to start", %{
    run: run,
    planner: planner
  } do
    {reply, run} = plan(run, planner, "Add a CSV export to the invoices page")

    assert reply.body =~ "I'd add a button there"
    assert reply.actions == ["start"]

    assert Enum.map(run.tasks, & &1.title) == [
             "Add the export button to the invoices page",
             "Write the CSV for the invoices shown"
           ]

    # The plan is the run's spec: agents read it, and it opens on the Spec page.
    spec = Specs.get_spec(run.spec_id)
    assert Enum.map(Specs.tasks(spec), & &1.title) == Enum.map(run.tasks, & &1.title)
    assert run.spec =~ "Write the CSV for the invoices shown"
    assert run.description =~ "Add a CSV export"

    # Asked again, the planner sees the tasks it wrote and adds to them.
    {_reply, run} = plan(run, planner, "Also cover an empty month")
    assert length(run.tasks) == 3
    assert List.last(run.tasks).title == "Test an empty month"
  end

  test "spec files attached for the planner become part of the run's spec", %{
    run: run,
    planner: planner
  } do
    {_reply, run} =
      plan(run, planner, "Plan this", [{"requirements.md", "# Export\n1. WHEN asked THEN export"}])

    spec = Specs.get_spec(run.spec_id)
    assert spec.requirements =~ "WHEN asked THEN export"
    assert run.spec =~ "WHEN asked THEN export"
    assert length(run.tasks) == 2
  end

  test "the planned tasks start the run", %{run: run, planner: planner} do
    # The engine is off in tests (config/test.exs): the run stays queued.
    {_reply, run} = plan(run, planner, "Add a CSV export")
    Chat.action(run, "start")

    assert %{status: "queued"} = Runs.get_run(run.id)
  end

  test "a tasks.md dropped into the chat is kept in the run's spec", %{run: run} do
    Chat.handle(run, "", [{"tasks.md", "# Login\n- [ ] 1. Add form\n- [ ] 2. Add session"}])
    run = Runs.get_run(run.id)

    assert Enum.map(run.tasks, & &1.title) == ["Add form", "Add session"]
    assert Specs.get_spec(run.spec_id).tasks =~ "- [ ] 1. Add form"
  end

  test "a run planned before it had a spec keeps its tasks when the spec is made", %{run: run} do
    {:ok, run} =
      Runs.attach_spec(run, [{"tasks.md", "- [ ] 1. Keep me\n- [ ] 2. And me"}], [
        %{ref: "1", title: "Keep me"},
        %{ref: "2", title: "And me"}
      ])

    spec = Specs.for_run(run)
    assert Enum.map(Specs.tasks(spec), & &1.title) == ["Keep me", "And me"]
    assert Enum.map(Runs.get_run(run.id).tasks, & &1.title) == ["Keep me", "And me"]
  end
end
