defmodule Factory.PlanningTest do
  # Not async: the planner asks the fake kiro-cli from a background task.
  use Factory.DataCase, async: false
  alias Factory.{Agents, Chat, ChatPlanner, Runs, Specs, Workflows}

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

  # The planner reaches Factory's plan tools over HTTP, as Kiro does (FactoryWeb.MCP).
  setup do
    server =
      start_supervised!(
        {Bandit, plug: FactoryWeb.Endpoint, ip: :loopback, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    Application.put_env(:factory, :mcp_url, "http://127.0.0.1:#{port}/mcp")
    on_exit(fn -> Application.delete_env(:factory, :mcp_url) end)
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

    # The reply is the planner's closing message, without what it said while working.
    assert reply.body =~ "I'd add a button there"
    refute reply.body =~ "Let me look"
    refute reply.body =~ "tool trouble"
    assert reply.actions == ["start"]
    assert reply.meta["tasks"] == Enum.map(run.tasks, & &1.title)

    assert Enum.map(run.tasks, & &1.title) == [
             "Add the export button to the invoices page",
             "Write the CSV for the invoices shown"
           ]

    # The plan is the run's spec: agents read it, and it opens on the Spec page.
    spec = Specs.get_spec(run.spec_id)
    assert Enum.map(Specs.tasks(spec), & &1.title) == Enum.map(run.tasks, & &1.title)
    assert run.spec =~ "Write the CSV for the invoices shown"
    assert run.description =~ "Add a CSV export"
    # The plan's approach opens the spec's design.
    assert spec.design =~ "# Approach"
    assert spec.design =~ "small CSV module"

    # Asked again, the planner sees the tasks it wrote and adds to them.
    {_reply, run} = plan(run, planner, "Also cover an empty month")
    assert length(run.tasks) == 3
    assert List.last(run.tasks).title == "Test an empty month"
  end

  test "the planner's live bubble shows what it's doing and the tasks so far", %{
    run: run,
    planner: planner
  } do
    {_reply, _run} = plan(run, planner, "Add a CSV export")

    assert_received {:agent_stream, %{text: "_Adding 2 tasks_" <> _}}

    # After each change the bubble lists the tasks; the last one lists both.
    progress = for {:agent_stream, %{text: "_Planning…_" <> tasks}} <- messages(), do: tasks
    assert List.last(progress) =~ "1. Add the export button to the invoices page"
    assert List.last(progress) =~ "2. Write the CSV for the invoices shown"
  end

  test "refining the plan changes only the tasks asked about and keeps the person's edits", %{
    run: run,
    planner: planner
  } do
    {_reply, run} = plan(run, planner, "Add a CSV export")

    # The person adds a note to task 1 on the Spec page.
    spec = Specs.get_spec(run.spec_id)

    edited =
      String.replace(
        spec.tasks,
        "invoices_live.ex`.",
        "invoices_live.ex`.\n  - Use the primary style"
      )

    {:ok, _} = Specs.update_spec(spec, %{tasks: edited})

    {reply, run} = plan(run, planner, "Rename it [test:edit]")

    refute reply.body =~ "tool trouble"
    assert Enum.map(run.tasks, & &1.title) == ["Add an Export CSV button"]
    assert Specs.get_spec(run.spec_id).tasks =~ "Use the primary style"
  end

  test "an unclear request gets questions and no tasks", %{run: run, planner: planner} do
    {reply, run} = plan(run, planner, "Export something [test:unclear]")

    assert reply.meta["unclear"]
    assert [%{"question" => "Which page gets the button?"}] = reply.meta["questions"]
    assert reply.body =~ "1. Which page gets the button? (Invoices / Reports)"
    assert reply.actions == []
    assert run.tasks == []
  end

  test "without the tools, the planner's JSON plan is used", %{run: run, planner: planner} do
    {reply, run} = plan(run, planner, "Plan it [test:json]")

    assert reply.body == "Planned without tools."
    assert Enum.map(run.tasks, & &1.title) == ["Add the export button to the invoices page"]
  end

  test "a replaced planner request can't change the plan", %{run: run, planner: planner} do
    old = Ecto.UUID.generate()
    run |> Ecto.Changeset.change(planner_generation: old) |> Repo.update!()
    token = Factory.PlanTools.grant(run.id, old, planner)
    run |> Ecto.Changeset.change(planner_generation: Ecto.UUID.generate()) |> Repo.update!()

    assert {:error, "This plan was replaced" <> _} =
             Factory.PlanTools.call(token, "add_tasks", %{"tasks" => [%{"title" => "Late"}]})

    assert Runs.get_run(run.id).tasks == []
    refute_received {:plan_tools, _, _}
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

  test "an older planner reply cannot replace the latest plan or post stale replies", %{
    run: run,
    planner: planner
  } do
    older = Ecto.UUID.generate()
    latest = Ecto.UUID.generate()
    run |> Ecto.Changeset.change(planner_generation: latest) |> Repo.update!()

    assert {:ok, :stale} = ChatPlanner.finish(run.id, older, planner, [], plan_result("Old task"))
    assert Runs.list_messages(run.id) == []
    assert Runs.get_run(run.id).tasks == []

    assert {:ok, :applied} =
             ChatPlanner.finish(run.id, latest, planner, [], plan_result("Latest task"))

    assert [%{title: "Latest task"}] = Runs.get_run(run.id).tasks
    assert [%{author: "Planner", actions: ["start"]}] = Runs.list_messages(run.id)

    assert {:ok, :stale} = ChatPlanner.finish(run.id, older, planner, [], {:error, "Old failure"})

    assert {:ok, :stale} =
             ChatPlanner.finish(run.id, latest, planner, [], plan_result("Duplicate result"))

    assert [%{title: "Latest task"}] = Runs.get_run(run.id).tasks
    assert length(Runs.list_messages(run.id)) == 1
  end

  for status <- ~w(queued running paused done cancelled) do
    test "a planner reply cannot replace tasks after the run becomes #{status}", %{
      run: run,
      planner: planner
    } do
      generation = Ecto.UUID.generate()
      spec = Specs.for_run(run)
      {:ok, _} = Specs.update_spec(spec, %{tasks: "- [ ] 1. Approved task\n"})

      Runs.get_run(run.id)
      |> Ecto.Changeset.change(status: unquote(status), planner_generation: generation)
      |> Repo.update!()

      assert {:ok, :stale} =
               ChatPlanner.finish(run.id, generation, planner, [], plan_result("Late task"))

      assert [%{title: "Approved task"}] = Runs.get_run(run.id).tasks
      assert Specs.get_spec(spec.id).tasks == "- [ ] 1. Approved task\n"
      assert Runs.list_messages(run.id) == []
    end
  end

  defp messages do
    receive do
      message -> [message | messages()]
    after
      0 -> []
    end
  end

  defp plan_result(title) do
    {:ok,
     %{
       reply: "Here's the plan",
       tasks: [%{"title" => title, "details" => [], "requirements" => [], "size" => nil}]
     }}
  end
end
