defmodule FactoryWeb.SpecLiveTest do
  use FactoryWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Factory.Specs

  test "creating a spec opens it on the overview step", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/specs")

    {:ok, view, _html} =
      view
      |> form("#new-spec", %{name: "Password reset"})
      |> render_submit()
      |> follow_redirect(conn)

    assert has_element?(view, "#spec-name input[value='Password reset']")
    assert has_element?(view, "#approve", "Skip overview")
  end

  test "writing, approving and moving through the steps to a run", %{conn: conn} do
    {:ok, spec} = Specs.create_spec("Password reset")
    {:ok, view, _html} = live(conn, ~p"/specs/#{spec.id}")
    # An empty step's box says what to write in it.
    assert has_element?(view, "#spec-overview[placeholder*='Write here the main spec']")
    assert has_element?(view, "#approve", "Skip overview")

    view |> element("#spec-editor") |> render_change(%{text: "# Overview\nResetting passwords"})
    assert has_element?(view, "#approve", "Approve overview")
    view |> element("#approve") |> render_click()
    assert_patch(view, ~p"/specs/#{spec.id}?step=requirements")
    assert has_element?(view, "#spec-requirements[placeholder*='Write here what you want']")
    assert has_element?(view, "button[phx-click=outline]", "Use an outline")

    view |> element("#spec-editor") |> render_change(%{text: "# Requirements\nA user can reset"})
    view |> element("#approve") |> render_click()
    assert_patch(view, ~p"/specs/#{spec.id}?step=design")

    view |> element("#spec-editor") |> render_change(%{text: "# Design"})
    view |> element("#approve") |> render_click()
    assert_patch(view, ~p"/specs/#{spec.id}?step=tasks")

    view |> element("#spec-editor") |> render_change(%{text: "- [ ] 1. Add the form"})
    assert has_element?(view, "#queue", "Queue tasks to choose which ones the next run does")
    refute has_element?(view, "#start-run")

    # Approving the last step makes the spec ready to run.
    view |> element("#approve") |> render_click()
    refute has_element?(view, "#approve")
    assert has_element?(view, "#start-run", "Start run")

    view |> element("#start-run") |> render_click()
    {path, _flash} = assert_redirect(view)
    assert path =~ ~r{^/chat/\d+$}
  end

  test "a locked step can't be written", %{conn: conn} do
    {:ok, spec} = Specs.create_spec("Locked")
    {:ok, view, _html} = live(conn, ~p"/specs/#{spec.id}?step=tasks")
    assert has_element?(view, "#step-locked", "Finish the Overview first")
    assert has_element?(view, "#step-locked a", "Go to Overview")
    refute has_element?(view, "#spec-editor")
  end

  test "dropping files into New spec fills the steps and starts a Kiro review", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/specs")

    files =
      file_input(view, "#new-spec", :files, [
        %{name: "requirements.md", content: "# Search filters\nFilter by date."},
        %{name: "tasks.md", content: "- [ ] 1. Add the date filter"}
      ])

    render_upload(files, "requirements.md")
    render_upload(files, "tasks.md")
    assert has_element?(view, "#new-spec", "requirements.md")
    assert has_element?(view, "#new-spec", "goes into requirements")
    assert has_element?(view, "#new-spec input[type=checkbox][name=review][checked]")

    {:ok, view, _html} =
      view
      |> form("#new-spec", %{name: "", review: "true"})
      |> render_submit()
      |> follow_redirect(conn)

    [spec] = Specs.list_specs()
    assert spec.name == "Search filters"
    assert spec.tasks == "- [ ] 1. Add the date filter"

    # The review finishes in the background and the panel updates.
    Specs.subscribe(spec.id)
    assert_receive {:spec_updated, %{review: %{"status" => "done"}}}, 5_000
    assert has_element?(view, "#review", "Needs work")
    assert has_element?(view, "#review", "Requirement 2 has no acceptance criteria.")
  end

  test "a spec can be deleted from the list", %{conn: conn} do
    {:ok, spec} = Specs.create_spec("Old idea")
    {:ok, view, _html} = live(conn, ~p"/specs")

    view |> element("#spec-#{spec.id} button[phx-click=delete]") |> render_click()
    refute has_element?(view, "#spec-#{spec.id}")
    assert Specs.get_spec(spec.id) == nil
  end

  test "a described feature becomes the overview and is named from it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/specs")
    description = "Users can export invoices as CSV.\nOne file per month."

    # The review box appears once there is something to review.
    refute has_element?(view, "#new-spec input[name=review]")
    view |> form("#new-spec", %{description: description}) |> render_change()
    assert has_element?(view, "#new-spec input[type=checkbox][name=review][checked]")

    {:ok, view, _html} =
      view
      |> form("#new-spec", %{name: "", description: description, review: "false"})
      |> render_submit()
      |> follow_redirect(conn)

    [spec] = Specs.list_specs()
    assert spec.name == "Users can export invoices as CSV."
    assert spec.overview == "Users can export invoices as CSV.\nOne file per month."
    assert spec.review == %{}
    # The spec opens on its overview, named from the first line.
    assert has_element?(view, "#spec-name input[value='Users can export invoices as CSV.']")
    assert has_element?(view, "#spec-overview", "Users can export invoices as CSV.")
  end

  test "uploading a file fills the open step, and replacing text can be undone", %{conn: conn} do
    {:ok, spec} = Specs.create_spec("Upload", %{overview: "My own notes"})
    {:ok, view, _html} = live(conn, ~p"/specs/#{spec.id}")

    file_input(view, "#spec-upload", :file, [%{name: "req.md", content: "# From the file"}])
    |> render_upload("req.md")

    assert Specs.get_spec(spec.id).overview == "# From the file"
    assert has_element?(view, "#spec-overview", "# From the file")
    assert has_element?(view, "#undo-upload", "Undo")

    view |> element("#undo-upload") |> render_click()
    assert Specs.get_spec(spec.id).overview == "My own notes"
    refute has_element?(view, "#undo-upload")
  end

  test "Kiro reads the project, asks questions, and the picked tasks are added", %{conn: conn} do
    {:ok, spec} = Specs.create_spec("Reset", %{requirements: "# R", design: "# D"})
    spec = approved_spec(spec)
    {:ok, view, _html} = live(conn, ~p"/specs/#{spec.id}?step=tasks")
    Specs.subscribe(spec.id)

    view |> element("#suggest-tasks") |> render_click()
    assert_patch(view, ~p"/specs/#{spec.id}?step=tasks&suggest")
    assert has_element?(view, "#suggest-window", "Read the project")

    view |> form("#plan-read", %{dir: File.cwd!()}) |> render_submit()
    assert has_element?(view, "#suggest-window", "Kiro is reading the project")
    assert_receive {:spec_updated, %{plan: %{"status" => "questions"}}}, 5_000

    # The recommended option starts picked; typing an answer of your own picks it instead.
    assert has_element?(view, "#plan-answers", "Where should the reset link go?")
    assert has_element?(view, ~s(input[name="answer[0]"][value="/reset"][checked]))

    view
    |> form("#plan-answers", %{answer: %{"0" => "/reset"}, other: %{"0" => "/account/reset"}})
    |> render_change()

    assert has_element?(view, ~s(input[name="answer[0]"][value="__other"][checked]))

    # Only one question has at least two options, so it's the last: Enter sends the answers.
    assert has_element?(view, "#plan-next", "Suggest tasks")
    view |> form("#plan-answers") |> render_submit()
    assert_receive {:spec_updated, %{plan: %{"status" => "tasks"}}}, 5_000
    assert has_element?(view, "#plan-pick", "Add the reset route (account)")
    assert has_element?(view, "#plan-add", "Add 2 tasks")

    view |> form("#plan-pick", %{pick: ["1"]}) |> render_change()
    assert has_element?(view, "#plan-add", "Add 1 task")

    view |> form("#plan-pick") |> render_submit()
    assert_patch(view, ~p"/specs/#{spec.id}?step=tasks")
    refute has_element?(view, "#suggest-window")

    spec = Specs.get_spec(spec.id)
    assert spec.tasks == "- [ ] 1. Send the email\n"
    assert spec.plan == %{}
  end

  test "the window opens at whatever stage Kiro is at", %{conn: conn} do
    {:ok, spec} = Specs.create_spec("Waiting", %{requirements: "# R", design: "# D"})
    spec = approved_spec(spec)

    questions = [
      %{"question" => "Which route?", "why" => "", "options" => ["/a", "/b"]},
      %{"question" => "Which name?", "why" => "", "options" => ["x", "y", "z"]}
    ]

    spec
    |> Ecto.Changeset.change(
      plan: %{"status" => "questions", "project" => "A Phoenix app.", "questions" => questions}
    )
    |> Factory.Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/specs/#{spec.id}?step=tasks&suggest")
    assert has_element?(view, "#plan-answers", "Which route?")
    assert has_element?(view, ~s(input[name="answer[0]"][value="/a"][checked]))

    # One question at a time: pick b, go on, come back, and b is still picked.
    view |> form("#plan-answers", %{answer: %{"0" => "/b"}}) |> render_change()
    view |> form("#plan-answers") |> render_submit()
    assert has_element?(view, "#plan-answers", "Which name?")
    assert has_element?(view, "#plan-next", "Suggest tasks")

    view
    |> element(~s(button[phx-click="plan_question"][phx-value-i="0"]), "Back")
    |> render_click()

    assert has_element?(view, ~s(input[name="answer[0]"][value="/b"][checked]))
  end

  test "tasks show as a list to select, reorder, delete and queue", %{conn: conn} do
    {:ok, spec} =
      Specs.create_spec("List", %{
        requirements: "# R",
        design: "# D",
        tasks: "- [ ] 1. Add `mix.exs` deps\n  - With ~> 1.0\n- [ ] 2. Write tests\n- [ ] 3. Ship"
      })

    spec = approved_spec(spec)
    {:ok, view, _html} = live(conn, ~p"/specs/#{spec.id}?step=tasks")

    # Code in a title shows as code; the ~ isn't read as formatting.
    assert has_element?(view, "#task-0 code", "mix.exs")
    assert has_element?(view, "#task-0", "With ~> 1.0")

    view |> element("#task-2 button[phx-click=task_move][phx-value-by='-1']") |> render_click()
    assert Specs.get_spec(spec.id).tasks =~ "- [ ] 2. Ship"

    view |> element("#task-filter") |> render_change(%{q: "tests"})
    assert has_element?(view, "#task-2", "Write tests")
    refute has_element?(view, "#task-0")
    view |> element("#task-filter") |> render_change(%{q: ""})

    # Select two, queue them; the queue lists them in order and starts the run.
    view |> element("#task-2 input[phx-click=task_select]") |> render_click()
    view |> element("#task-0 input[phx-click=task_select]") |> render_click()
    view |> element("button[phx-click=queue_selected]") |> render_click()
    assert Specs.get_spec(spec.id).queue == ["Add `mix.exs` deps", "Write tests"]
    assert has_element?(view, "#queue li", "Write tests")

    view |> element("#task-1 button[phx-click=task_delete]") |> render_click()
    assert length(Specs.task_list(Specs.get_spec(spec.id))) == 2

    view |> element("#approve") |> render_click()
    assert has_element?(view, "#start-run", "Start run with 2 queued")
    refute has_element?(view, "button[phx-click=task_move]")

    view |> element("#start-queue") |> render_click()
    {path, _flash} = assert_redirect(view)
    ["", "chat", run_id] = String.split(path, "/")

    assert Enum.map(Factory.Runs.get_run(run_id).tasks, & &1.title) ==
             ["Add `mix.exs` deps", "Write tests"]
  end

  test "a task is edited in place and keeps its place in the queue", %{conn: conn} do
    {:ok, spec} =
      Specs.create_spec("Edit", %{
        requirements: "# R",
        design: "# D",
        tasks: "# Tasks\n\n- [ ] 1. Old\n  - A step\n  - _Requirements: 1.1_\n- [x] 2. Done one"
      })

    spec = approved_spec(spec)
    {:ok, spec} = Specs.queue_tasks(spec, ["Old"])
    {:ok, view, _html} = live(conn, ~p"/specs/#{spec.id}?step=tasks")

    view |> element("#task-0 button[phx-click=task_edit]") |> render_click()
    assert has_element?(view, "#task-edit-0 textarea[name=details]", "A step")

    view |> element("#task-edit-0") |> render_submit(%{title: "", details: "", requirements: ""})
    assert Specs.get_spec(spec.id).tasks =~ "1. Old"

    view
    |> element("#task-edit-0")
    |> render_submit(%{title: "New", details: "First\n\n Second ", requirements: "1.1, 2.3,"})

    spec = Specs.get_spec(spec.id)

    assert spec.tasks ==
             "# Tasks\n\n- [ ] 1. New\n  - First\n  - Second\n  - _Requirements: 1.1, 2.3_\n\n- [x] 2. Done one\n"

    assert spec.queue == ["New"]
    refute has_element?(view, "#task-edit-0")
    assert has_element?(view, "#task-0", "New")
  end

  test "an approved task can be edited, or improved with Kiro", %{conn: conn} do
    {:ok, spec} =
      Specs.create_spec("Improve", %{
        requirements: "# R",
        design: "# D",
        tasks: "- [ ] 1. Vague\n- [ ] 2. Other"
      })

    spec = approved_spec(spec)
    {:ok, spec} = Specs.approve(spec, "tasks")
    {:ok, spec} = Specs.queue_tasks(spec, ["Vague"])
    {:ok, view, _html} = live(conn, ~p"/specs/#{spec.id}?step=tasks")
    Specs.subscribe(spec.id)

    # Approved: one task can still change, but the list can't be reordered.
    refute has_element?(view, "button[phx-click=task_move]")
    view |> element("#task-1 button[phx-click=task_edit]") |> render_click()
    view |> element("#task-edit-1") |> render_submit(%{title: "Other one", details: ""})
    assert Specs.get_spec(spec.id).tasks =~ "- [ ] 2. Other one"

    view |> element("#task-0 button[phx-click=improve_open]") |> render_click()

    view
    |> element("#task-0 form[phx-submit=improve_send]")
    |> render_submit(%{instruction: "name the file"})

    assert has_element?(view, "#task-0 .loading")
    assert_receive {:task_improved, "Vague", {:ok, _}}, 5_000

    assert has_element?(view, "#task-0", "Better: name the file")
    assert has_element?(view, "#task-0 code", "lib/a.ex")
    # Nothing changes until it's applied.
    assert Specs.get_spec(spec.id).tasks =~ "1. Vague"

    view |> element("#task-0 button[phx-click=improve_apply]") |> render_click()
    spec = Specs.get_spec(spec.id)

    assert spec.tasks =~
             "- [ ] 1. Better: name the file\n  - Edit `lib/a.ex`.\n  - Then test it.\n  - _Requirements: 1.1_"

    assert spec.queue == ["Better: name the file"]
    assert spec.tasks_approved_at
    refute has_element?(view, "#task-0 button[phx-click=improve_apply]")
  end

  test "a new task is added as is, or written by Kiro and reviewed first", %{conn: conn} do
    {:ok, spec} =
      Specs.create_spec("Add", %{requirements: "# R", design: "# D", tasks: "- [ ] 1. First"})

    spec = approved_spec(spec)
    {:ok, view, _html} = live(conn, ~p"/specs/#{spec.id}?step=tasks")
    Specs.subscribe(spec.id)

    view |> element("#add-task") |> render_click()

    view
    |> form("#task-draft", %{title: "Second", notes: "One step\nAnother"})
    |> render_submit(%{action: "add"})

    assert Specs.get_spec(spec.id).tasks =~ "- [ ] 2. Second\n  - One step\n  - Another"
    refute has_element?(view, "#new-task")
    assert has_element?(view, "#task-1.task-card-active")

    view |> element("#add-task") |> render_click()

    view
    |> form("#task-draft", %{title: "Export CSV", notes: ""})
    |> render_submit(%{action: "refine"})

    assert has_element?(view, "#new-task .loading")
    assert_receive {:task_drafted, _, {:ok, _}}, 5_000

    assert has_element?(view, "#new-task", "Scoped: Export CSV")
    assert has_element?(view, "#new-task code", "lib/export.ex")
    assert length(Specs.task_list(Specs.get_spec(spec.id))) == 2

    view |> element("#draft-accept") |> render_click()

    assert Specs.get_spec(spec.id).tasks =~
             "- [ ] 3. Scoped: Export CSV\n  - Add `lib/export.ex`.\n  - Test it in `test/export_test.exs`.\n  - _Requirements: 2.1_"

    refute has_element?(view, "#new-task")
  end

  test "Queue all queues every task in list order", %{conn: conn} do
    {:ok, spec} =
      Specs.create_spec("All", %{
        requirements: "# R",
        design: "# D",
        tasks: "- [ ] 1. A\n- [ ] 2. B\n- [ ] 3. C"
      })

    spec = approved_spec(spec)
    {:ok, spec} = Specs.queue_tasks(spec, ["B"])
    {:ok, view, _html} = live(conn, ~p"/specs/#{spec.id}?step=tasks")

    view |> element("#queue-all") |> render_click()
    assert Specs.get_spec(spec.id).queue == ["B", "A", "C"]
    refute has_element?(view, "#queue-all")
  end

  test "deleting a spec asks in a window first", %{conn: conn} do
    {:ok, spec} = Specs.create_spec("Keep me")
    {:ok, view, _html} = live(conn, ~p"/specs/#{spec.id}")

    refute has_element?(view, "#confirm-delete")
    view |> element("#ask-delete") |> render_click()
    assert has_element?(view, "#confirm-delete", "Delete “Keep me”?")

    view |> element("#confirm-delete button", "Cancel") |> render_click()
    refute has_element?(view, "#confirm-delete")
    assert Specs.get_spec(spec.id)

    view |> element("#ask-delete") |> render_click()
    view |> element("#confirm-delete-button") |> render_click()
    assert_redirect(view, ~p"/specs")
    refute Specs.get_spec(spec.id)
  end

  test "Kiro can write the missing parts from the spec's side panel", %{conn: conn} do
    {:ok, spec} = Specs.create_spec("Login", %{overview: "Users land on their dashboard."})
    {:ok, spec} = Specs.set_project_dir(spec, File.cwd!())
    {:ok, view, _html} = live(conn, ~p"/specs/#{spec.id}")

    assert has_element?(view, "#write-missing", "Write the requirements, design and tasks")
    Specs.subscribe(spec.id)
    view |> element("#write-missing") |> render_click()
    assert has_element?(view, "#write-panel", "Kiro is reading the project")

    # Kiro writes the parts, then QA reviews them.
    assert_receive {:spec_updated, %{review: %{"status" => "done"}}}, 5_000
    assert has_element?(view, "#write-panel", "Wrote the requirements, design and tasks.")
    refute has_element?(view, "#write-missing")
  end

  test "a run's spec links back to its chat and picks the rules the run follows", %{conn: conn} do
    {:ok, rules} = Specs.create_base_spec("Testing", "Every change has a test.")
    {:ok, run} = Factory.Runs.create_run("Export")
    spec = Specs.for_run(run)
    {:ok, view, _html} = live(conn, ~p"/specs/#{spec.id}")

    assert has_element?(view, "a[href='/chat/#{run.id}']", "Export")
    view |> element("#run-base-specs-#{rules.id}") |> render_click()
    assert Factory.Runs.get_run(run.id).settings["base_spec_ids"] == [rules.id]
  end
end
