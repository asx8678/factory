defmodule Factory.ChatTest do
  # Not async: messages to agents start (fake) Kiro sessions, which need the shared sandbox.
  use Factory.DataCase, async: false
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

  test "in an agent's view, plain text goes to that agent and replies are tagged with it" do
    {:ok, agent} = Factory.Agents.create_agent(%{name: "Planner"})
    on_exit(fn -> Factory.Kiro.stop(agent.id) end)
    {:ok, run} = Runs.create_run()
    Runs.subscribe(run.id)
    Chat.handle(run, "plan the login page", [], to: agent)
    assert_receive {:message, %{author: "Planner"}}, 5_000
    Chat.handle(run, "/status", [], to: agent)

    [ask, reply, status_cmd, status_reply] = Runs.list_messages(run.id)
    assert ask.meta == %{"to_agent_id" => agent.id}
    assert reply.meta["agent_id"] == agent.id
    assert reply.body == "echo: plan the login page"
    assert status_cmd.meta == %{"to_agent_id" => agent.id}
    assert status_reply.meta == %{"agent_id" => agent.id}
    assert status_reply.body =~ "Run is draft"
  end

  test "/ask from the All view is tagged with the agent it names" do
    # A unique name, so agents left in the test database can't match instead.
    name = "Planner #{System.unique_integer([:positive])}"
    {:ok, agent} = Factory.Agents.create_agent(%{name: name})
    on_exit(fn -> Factory.Kiro.stop(agent.id) end)
    {:ok, run} = Runs.create_run()
    Runs.subscribe(run.id)
    Chat.handle(run, "/ask #{name} hi")
    assert_receive {:message, %{author: ^name}}, 5_000

    [ask, reply] = Runs.list_messages(run.id)
    assert ask.meta == %{"to_agent_id" => agent.id}
    assert reply.meta["agent_id"] == agent.id
  end
end
