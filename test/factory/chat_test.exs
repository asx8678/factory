defmodule Factory.ChatTest do
  use Factory.DataCase, async: true
  alias Factory.{Chat, Runs}

  defp replies(run),
    do:
      run.id
      |> Runs.list_messages()
      |> Enum.filter(&(&1.role == "factory"))
      |> Enum.map(& &1.body)

  test "attaching tasks.md creates tasks and offers to start" do
    {:ok, run} = Runs.create_run()
    Chat.handle(run, "", [{"tasks.md", "# Login\n- [ ] 1. Add form\n- [ ] 2. Add session"}])

    run = Runs.get_run(run.id)
    assert run.title == "Login"
    assert Enum.map(run.tasks, & &1.title) == ["Add form", "Add session"]
    assert [reply] = replies(run)
    assert reply =~ "Found 2 tasks in tasks.md"

    assert [%{actions: ["start"]}] =
             run.id |> Runs.list_messages() |> Enum.filter(&(&1.role == "factory"))
  end

  test "/run needs tasks, then queues the run; /pause and /resume change status" do
    {:ok, run} = Runs.create_run()
    Chat.handle(run, "/run")
    assert List.last(replies(run)) =~ "nothing to run"

    Chat.handle(Runs.get_run(run.id), "", [{"tasks.md", "1. Only task"}])
    Chat.handle(Runs.get_run(run.id), "/run")
    assert Runs.get_run(run.id).status == "queued"

    Chat.handle(Runs.get_run(run.id), "/pause")
    assert Runs.get_run(run.id).status == "paused"
    Chat.handle(Runs.get_run(run.id), "/resume")
    assert Runs.get_run(run.id).status == "queued"
  end

  test "unknown commands and plain text point to /help" do
    {:ok, run} = Runs.create_run()
    Chat.handle(run, "/fly")
    Chat.handle(run, "build me a login page")
    assert [a, b] = replies(run)
    assert a =~ "no /fly command"
    assert b =~ "/help"
  end
end
