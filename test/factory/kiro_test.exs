defmodule Factory.KiroTest do
  # Not async: the Kiro session is a separate process that needs the shared sandbox.
  use Factory.DataCase, async: false
  alias Factory.{Agents, Chat, Kiro, Runs}

  setup do
    # Agent names must be unique for /ask; ignore anything left in the test database.
    Factory.Repo.delete_all(Factory.Agents.Agent)
    {:ok, agent} = Agents.create_agent(%{name: "Coder", runtime: "kiro_v3"})
    {:ok, run} = Runs.create_run()
    Runs.subscribe(run.id)
    on_exit(fn -> Kiro.stop(agent.id) end)
    %{agent: agent, run: run}
  end

  test "switching an agent to Kiro picks a Kiro model", %{agent: agent} do
    assert agent.model == "auto"
  end

  test "/ask streams the reply into the chat and posts it with credits", %{run: run} do
    Chat.handle(run, "/ask Coder hello there")

    assert_receive {:agent_stream, %{name: "Coder", text: "echo: "}}, 5_000
    assert_receive {:message, %{author: "Coder", body: "echo: hello there", meta: meta}}, 5_000
    assert meta["credits"] == 0.05
    assert meta["stop_reason"] == "end_turn"
    assert %{status: "idle", activity: nil} = Agents.get_agent(meta["agent_id"])

    # The turn is recorded as usage of this run.
    assert %{calls: 1, credits: 0.05, tokens: tokens} = Factory.Usage.totals({:run, run.id})
    assert tokens > 0
  end

  test "requests to write files are denied and noted", %{run: run} do
    Chat.handle(run, "/ask Coder please write a file")

    assert_receive {:message, %{author: "Coder", body: body}}, 5_000
    assert body =~ "[deny] echo: please write a file"
    assert body =~ "Denied: Write notes.md"
  end

  test "a model Kiro refuses is reported in the chat and marks the agent failed", %{
    agent: agent,
    run: run
  } do
    # Bypass the changeset so the fake Kiro receives a model it rejects.
    Factory.Repo.update_all(Factory.Agents.Agent, set: [model: "bad-model"])
    Chat.handle(run, "/ask Coder hi")

    assert_receive {:message,
                    %{body: "Coder couldn't start: Kiro couldn't set model to bad-model" <> _}},
                   5_000

    assert %{status: "error"} = Agents.get_agent(agent.id)
  end

  test "a model Kiro doesn't report back still works; a different one is a refusal", %{
    agent: agent,
    run: run
  } do
    # The fake Kiro answers deepseek-3.2 without any settings, and glm-5 by reporting "auto".
    {:ok, _} = Agents.update_agent(agent, %{model: "deepseek-3.2"})
    Chat.handle(run, "/ask Coder hi")
    assert_receive {:message, %{author: "Coder", body: "echo: hi"}}, 5_000

    Kiro.stop(agent.id)
    {:ok, _} = Agents.update_agent(Agents.get_agent(agent.id), %{model: "glm-5"})
    Chat.handle(run, "/ask Coder hi")

    assert_receive {:message,
                    %{
                      body:
                        "Coder couldn't start: Kiro didn't accept model glm-5 (it reports auto)."
                    }},
                   5_000
  end

  test "the agent's context goes with the first message of a session only", %{
    agent: agent,
    run: run
  } do
    {:ok, _} = Agents.update_agent(agent, %{prompt: "Be brief."})
    Chat.handle(run, "/ask Coder one")

    assert_receive {:message,
                    %{author: "Coder", body: "echo: <context>\nBe brief.\n</context>\n\none"}},
                   5_000

    Chat.handle(run, "/ask Coder two")
    assert_receive {:message, %{author: "Coder", body: "echo: two"}}, 5_000
  end

  test "each reply records credits and context, and the agent keeps running totals", %{
    agent: agent,
    run: run
  } do
    Chat.handle(run, "/ask Coder one")
    assert_receive {:message, %{author: "Coder", meta: meta}}, 5_000

    assert %{
             "credits" => 0.05,
             "context_pct" => 2.0,
             "window" => 1_000_000,
             "context_tokens" => 20_000
           } = meta

    Chat.handle(run, "/ask Coder two")
    assert_receive {:message, %{author: "Coder", body: "echo: two"}}, 5_000

    usage = Agents.get_agent(agent.id).usage
    assert usage["turns"] == 2
    assert_in_delta usage["credits"], 0.10, 0.0001
    assert usage["window"] == 1_000_000
    assert %{turns: 2} = Runs.usage(run.id)
  end

  test "agents in the shared session use one Kiro session, labelled and in turn", %{
    agent: coder,
    run: run
  } do
    {:ok, coder} = Agents.update_agent(coder, %{session: "shared", prompt: "Write code."})

    {:ok, tester} =
      Agents.create_agent(%{
        name: "Tester",
        runtime: "kiro_v3",
        session: "shared",
        model: "claude-haiku-4.5"
      })

    on_exit(fn -> Kiro.stop(:shared) end)

    # Both ask at once: the second waits for the first.
    Chat.handle(run, "/ask Coder one")
    Chat.handle(run, "/ask Tester two")

    assert_receive {:message, %{author: "Coder", body: body1, meta: %{"session" => "shared"}}},
                   5_000

    assert_receive {:message, %{author: "Tester", body: body2, meta: %{"session" => "shared"}}},
                   5_000

    assert body1 == ~s(echo: <context agent="Coder">\nWrite code.\n</context>\n\n[Coder] one)
    assert body2 == "echo: [Tester] two"
    assert Kiro.whereis(:shared)
    refute Kiro.whereis(coder.id)
    refute Kiro.whereis(tester.id)
  end

  test "compacting needs a running session and shows its result", %{
    agent: agent,
    run: run
  } do
    assert {:error, :no_session} = Kiro.compact(agent)

    Chat.handle(run, "/ask Coder hi")
    assert_receive {:message, %{author: "Coder"}}, 5_000

    Agents.subscribe()
    assert :ok = Kiro.compact(Agents.get_agent(agent.id))

    # "Compacting context", then "Context compacted" once Kiro confirms.
    assert_receive {:graph_changed}, 5_000
    assert_receive {:graph_changed}, 5_000
    assert_receive {:graph_changed}, 5_000
    compacted = Agents.get_agent(agent.id)
    assert %{status: "done", activity: "Context compacted"} = compacted
    assert compacted.usage["compacted_from"] == 2.0
    refute Map.has_key?(compacted.usage, "context_pct")

    # The next reply shows the new size and what it was before; then that note is dropped.
    Chat.handle(run, "/ask Coder again")

    assert_receive {:message,
                    %{author: "Coder", meta: %{"compacted_from" => 2.0, "context_pct" => 2.0}}},
                   5_000

    refute Map.has_key?(Agents.get_agent(agent.id).usage, "compacted_from")
  end

  test "the graph says whether an agent's session is live; startup clears stale context", %{
    agent: agent,
    run: run
  } do
    live = fn ->
      Enum.find(Agents.graph(agent.workflow_id).nodes, &(&1.id == "#{agent.id}")).live
    end

    refute live.()

    Chat.handle(run, "/ask Coder hi")
    assert_receive {:message, %{author: "Coder"}}, 5_000
    assert live.()
    assert Agents.get_agent(agent.id).usage["context_pct"]

    Kiro.stop(agent.id)
    refute live.()

    # As after a restart: context left behind is cleared, totals stay.
    Agents.record_usage(agent.id, %{"turns" => 1, "credits" => 0.05, "context_pct" => 2.0})
    Agents.reset_sessions()

    assert %{usage: %{"turns" => 1, "credits" => 0.05} = usage, status: "idle"} =
             Agents.get_agent(agent.id)

    refute Map.has_key?(usage, "context_pct")
  end

  test "agents not on Kiro get directions instead", %{run: run} do
    {:ok, _} = Agents.create_agent(%{name: "Planner"})
    Chat.handle(run, "/ask Planner hi")

    assert_receive {:message, %{role: "factory", author: nil, body: body}}, 1_000
    assert body =~ "isn't connected to Kiro"
  end
end
