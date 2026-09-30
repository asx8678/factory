defmodule Factory.SpecsTest do
  use Factory.DataCase, async: true
  alias Factory.{Runs, Specs}
  alias Factory.Specs.{Review, Spec}

  setup do
    {:ok, spec} = Specs.create_spec("Password reset")
    %{spec: spec}
  end

  test "steps open in order, each after the one before is approved", %{spec: spec} do
    assert Spec.current_step(spec) == "overview"
    refute Spec.open?(spec, "requirements")

    # The overview can be skipped: approved while empty.
    {:ok, spec} = Specs.approve(spec, "overview")
    assert Spec.current_step(spec) == "requirements"
    refute Spec.open?(spec, "design")
    assert {:error, :locked} = Specs.approve(spec, "design")
    assert {:error, :empty} = Specs.approve(spec, "requirements")

    {:ok, spec} = Specs.update_spec(spec, %{requirements: "# Requirements\nAs a user…"})
    {:ok, spec} = Specs.approve(spec, "requirements")
    assert Spec.open?(spec, "design")
    assert Spec.current_step(spec) == "design"
  end

  test "tasks can't be approved without a task in them", %{spec: spec} do
    spec = approved(spec, ~w(overview requirements design))
    {:ok, spec} = Specs.update_spec(spec, %{tasks: "Just some notes"})
    assert {:error, :no_tasks} = Specs.approve(spec, "tasks")
  end

  test "reopening a step reopens every step after it", %{spec: spec} do
    spec = approved(spec, ~w(overview requirements design tasks))
    assert Spec.current_step(spec) == "ready"

    {:ok, spec} = Specs.reopen(spec, "design")
    assert Spec.approved?(spec, "requirements")
    refute Spec.approved?(spec, "design")
    refute Spec.approved?(spec, "tasks")
  end

  test "an approved spec starts a run with its files and tasks", %{spec: spec} do
    assert {:error, :not_approved} = Specs.start_run(spec)

    spec = approved(spec, ~w(overview requirements design tasks))
    {:ok, run} = Specs.start_run(spec)

    run = Runs.get_run(run.id)
    assert run.title == "Password reset"
    assert run.spec_id == spec.id
    assert run.spec_files == ~w(requirements.md design.md tasks.md)
    assert Enum.map(run.tasks, & &1.title) == ["Add the form", "Send the email"]
    assert [%{body: "Found 2 tasks in tasks.md" <> _}] = Runs.list_messages(run.id)
  end

  test "writing a run's spec reports its missing workflow", %{spec: spec} do
    {:ok, workflow} = Factory.Workflows.create("Deleted workflow")
    {:ok, _} = Factory.Workflows.delete(workflow)
    {:ok, run} = Runs.create_run()

    {:ok, _} =
      Runs.update_run(run, %{spec_id: spec.id, settings: %{"workflow_id" => workflow.id}})

    assert {:ok, %{plan: %{"write" => %{"status" => "error", "error" => message}}}} =
             Specs.write_missing(Specs.get_spec(spec.id))

    assert message =~ "workflow no longer exists"
  end

  test "attaching a spec uses the latest title rather than the caller's stale run" do
    {:ok, stale} = Runs.create_run()
    {:ok, _} = Runs.update_run(stale, %{title: "Renamed while editing"})

    {:ok, run} =
      Runs.attach_spec(stale, [{"tasks.md", "# Old heading\n1. Task"}], [
        %{ref: "1", title: "Task"}
      ])

    assert run.title == "Renamed while editing"
  end

  test "run list totals use one grouped usage query and include zero-use runs", %{spec: spec} do
    {:ok, first} = Runs.create_run("Used")
    {:ok, second} = Runs.create_run("Unused")
    {:ok, _} = Runs.update_run(first, %{spec_id: spec.id})

    for credits <- [0.25, 0.5] do
      {:ok, _} =
        Factory.Usage.record(%{
          run_id: first.id,
          credits: credits,
          input_tokens: 10,
          output_tokens: 5
        })
    end

    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:factory, :repo, :query],
      fn _, _, metadata, parent ->
        if self() == parent and metadata.query =~ ~s("usage_events"),
          do: send(parent, :usage_query)
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    listed = Runs.list_runs_with_usage()
    assert_receive :usage_query
    refute_received :usage_query

    assert {loaded, %{credits: 0.75, tokens: 30, calls: 2}} =
             Enum.find(listed, fn {r, _} -> r.id == first.id end)

    assert loaded.spec_doc.id == spec.id

    assert {_, %{credits: +0.0, tokens: 0, calls: 0}} =
             Enum.find(listed, fn {r, _} -> r.id == second.id end)
  end

  test "active run counts have a partial status index" do
    %{rows: [[definition]]} =
      Repo.query!(
        "SELECT indexdef FROM pg_indexes WHERE schemaname = current_schema() AND indexname = 'runs_active_status_index'"
      )

    assert definition =~ "(status) WHERE"
    assert definition =~ "queued"
    assert definition =~ "running"
  end

  test "files go into the step their name says, and name the spec" do
    {:ok, spec} =
      Specs.create_from_files("", [
        {"tasks.md", "- [ ] 1. Build it"},
        {"feature.md", "# Dark mode\nUsers can switch themes."},
        {"design.md", "# Design"},
        {"requirements.md", "# Requirements"}
      ])

    assert spec.name == "Dark mode"
    # A file without a step in its name is the main spec.
    assert spec.overview =~ "Users can switch themes."
    assert spec.requirements == "# Requirements"
    assert spec.design == "# Design"
    assert spec.tasks == "- [ ] 1. Build it"
  end

  test "Kiro reviews a spec in the background and scores it", %{spec: spec} do
    assert {:error, :empty} = Specs.review(spec)

    {:ok, spec} = Specs.update_spec(spec, %{requirements: "# Requirements\nReset by email"})
    Specs.subscribe(spec.id)
    {:ok, spec} = Specs.review(spec)
    assert spec.review["status"] == "running"
    assert {:error, :running} = Specs.review(spec)

    assert_receive {:spec_updated, %{review: %{"status" => "done"} = review} = spec}, 5_000
    assert review["score"] == 62
    assert review["verdict"] == "needs_work"
    # Checks Factory doesn't know are dropped; the rest keep the known order.
    assert Enum.map(review["checks"], & &1["id"]) == ["requirements", "acceptance"]
    assert review["improvements"] == ["Add WHEN/THEN criteria to Requirement 2."]
    refute Specs.changed_since_review?(spec)

    # The review is recorded as the spec's usage, with Kiro's credits.
    assert [%{source: "review", credits: 0.25, ok: true}] =
             Factory.Repo.all(Factory.Usage.Event)
             |> Enum.filter(&(&1.spec_id == spec.id))

    {:ok, spec} = Specs.update_spec(spec, %{requirements: "# Requirements\nChanged"})
    assert Specs.changed_since_review?(spec)
  end

  test "a reply that isn't a review is reported as an error", %{spec: spec} do
    {:ok, spec} = Specs.update_spec(spec, %{requirements: "unreadable"})
    Specs.subscribe(spec.id)
    {:ok, _} = Specs.review(spec)

    assert_receive {:spec_updated, %{review: %{"status" => "error", "error" => error}}}, 5_000
    assert error =~ "wasn't a review"
  end

  test "a review parses JSON wrapped in prose or a code fence" do
    assert {:ok, %{"score" => 85, "verdict" => "strong"}} =
             Review.parse("Here you go:\n```json\n{\"score\": 85.4, \"checks\": []}\n```")

    assert {:ok, %{"score" => 100}} = Review.parse(~s({"score": 140}))
    assert {:error, _} = Review.parse(~s({"summary": "no score"}))
  end

  describe "suggesting tasks" do
    setup %{spec: spec} do
      {:ok, spec} = Specs.update_spec(spec, %{requirements: "# R\n1. Reset by email"})
      Specs.subscribe(spec.id)
      %{spec: spec, dir: File.cwd!()}
    end

    test "Kiro reads the project (reads allowed) and asks questions", %{spec: spec, dir: dir} do
      assert {:error, :no_folder} = Specs.plan_questions(spec, "/no/such/folder")

      {:ok, spec} = Specs.plan_questions(spec, dir)
      assert spec.plan["status"] == "reading"
      assert spec.project_dir == dir
      assert {:error, :running} = Specs.plan_questions(spec, dir)

      assert_receive {:plan_activity, "Reading mix.exs"}, 5_000
      assert_receive {:spec_updated, %{plan: %{"status" => "questions"} = plan}}, 5_000
      assert plan["project"] =~ "Read permission: allow."
      # A question needs at least two options.
      assert [%{"question" => "Where should the reset link go?", "options" => ["/reset", _]}] =
               plan["questions"]
    end

    test "with answers, Kiro suggests tasks that can be added to the spec", %{
      spec: spec,
      dir: dir
    } do
      {:ok, _} = Specs.plan_questions(spec, dir)
      assert_receive {:spec_updated, %{plan: %{"status" => "questions"}} = spec}, 5_000

      answers = [%{"question" => "Where should the reset link go?", "answer" => "/account/reset"}]
      {:ok, _} = Specs.plan_tasks(spec, answers)
      assert_receive {:spec_updated, %{plan: %{"status" => "tasks"} = plan} = spec}, 5_000

      assert plan["answers"] == answers
      # Tasks without a title are dropped; an unknown size is cleared.
      assert [
               %{"title" => "Add the reset route (account)", "size" => "S"},
               %{"title" => "Send the email", "size" => nil}
             ] = plan["tasks"]

      {:ok, spec} = Specs.update_spec(spec, %{tasks: "- [ ] 1. Existing task"})
      {:ok, spec} = Specs.add_tasks(spec, plan["tasks"])

      assert spec.tasks == """
             - [ ] 1. Existing task

             - [ ] 2. Add the reset route (account)
               - In router.ex.
               - _Requirements: 1.1_

             - [ ] 3. Send the email
             """

      {:ok, spec} = Specs.add_tasks(spec, tl(plan["tasks"]), :replace)
      assert spec.tasks == "- [ ] 1. Send the email\n"
    end
  end

  describe "managing tasks" do
    setup %{spec: spec} do
      {:ok, spec} =
        Specs.update_spec(spec, %{
          requirements: "# R",
          design: "# D",
          tasks:
            "# Plan\n\n- [ ] 1. One\n  - `a` detail\n  - _Requirements: 1.1_\n- [ ] 2. Two\n- [ ] 3. Three\n"
        })

      {:ok, spec} = Specs.approve(spec, "overview")
      {:ok, spec} = Specs.approve(spec, "requirements")
      {:ok, spec} = Specs.approve(spec, "design")
      %{spec: spec}
    end

    test "tasks are read with their details and requirements", %{spec: spec} do
      assert [one, _, _] = Specs.task_list(spec)
      assert one.title == "One"
      assert one.details == ["`a` detail"]
      assert one.requirements == ["1.1"]
      assert one.queued == nil
    end

    test "moving and deleting rewrite and renumber the text", %{spec: spec} do
      {:ok, spec} = Specs.move_task(spec, 2, -1)
      assert Enum.map(Specs.task_list(spec), & &1.title) == ["One", "Three", "Two"]
      assert spec.tasks =~ "- [ ] 2. Three"

      {:ok, spec} = Specs.queue_tasks(spec, ["Two", "One"])
      {:ok, spec} = Specs.delete_tasks(spec, [0])
      assert spec.tasks == "# Plan\n\n- [ ] 1. Three\n\n- [ ] 2. Two\n"
      # A deleted task leaves the queue too.
      assert spec.queue == ["Two"]

      {:ok, spec} = Specs.approve(spec, "tasks")
      assert {:error, :locked} = Specs.move_task(spec, 0, 1)
    end

    test "a run from the queue does only the queued tasks, in queue order", %{spec: spec} do
      {:ok, spec} = Specs.queue_tasks(spec, ["Three", "One"])
      {:ok, spec} = Specs.queue_tasks(spec, ["One", "Two"])
      assert spec.queue == ["Three", "One", "Two"]

      {:ok, spec} = Specs.move_queued(spec, "Two", -1)
      {:ok, spec} = Specs.unqueue_tasks(spec, ["Three"])
      assert spec.queue == ["Two", "One"]
      assert [%{queued: 1}, %{queued: 0}, %{queued: nil}] = Specs.task_list(spec)

      {:ok, spec} = Specs.approve(spec, "tasks")
      {:ok, run} = Specs.start_run(spec)

      assert Enum.map(Runs.get_run(run.id).tasks, & &1.title) == ["Two", "One"]
      assert Specs.get_spec(spec.id).queue == []
    end
  end

  defp approved(spec, steps) do
    {:ok, spec} =
      Specs.update_spec(spec, %{
        requirements: "# Requirements",
        design: "# Design",
        tasks: "- [ ] 1. Add the form\n- [ ] 2. Send the email"
      })

    Enum.reduce(steps, spec, fn step, spec ->
      {:ok, spec} = Specs.approve(spec, step)
      spec
    end)
  end

  describe "writing the missing parts" do
    test "Kiro writes what the spec lacks, keeps what it has, then QA reviews it" do
      {:ok, spec} =
        Specs.create_spec("Login", %{overview: "# Login\nUsers land on their dashboard."})

      {:ok, spec} = Specs.set_project_dir(spec, File.cwd!())
      Specs.subscribe(spec.id)

      assert {:ok, %{plan: %{"write" => %{"status" => "running"}}}} = Specs.write_missing(spec)
      assert_receive {:spec_updated, %{plan: %{"write" => %{"status" => "done"} = write}}}, 5_000

      spec = Specs.get_spec(spec.id)
      assert write["wrote"] == ~w(requirements design tasks)
      assert spec.overview =~ "Users land on their dashboard."
      assert spec.requirements =~ "WHEN a user logs in"
      assert spec.design =~ "session_controller.ex"

      assert Enum.map(Specs.tasks(spec), & &1.title) == [
               "Add a failing test for the redirect",
               "Keep the return path"
             ]

      # Then QA reviews what Kiro wrote.
      assert_receive {:spec_updated, %{review: %{"status" => "done"}}}, 5_000

      assert {:error, :nothing_missing} = Specs.write_missing(spec)
    end
  end
end
