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

  test "an agent that changes code may edit; one that only checks may not", %{
    agent: agent,
    run: run
  } do
    Chat.handle(run, "/ask Coder please write a file")
    assert_receive {:message, %{author: "Coder", body: body}}, 5_000
    assert body =~ "[allow] echo: please write a file"
    refute body =~ "Denied"

    {:ok, _} = Agents.update_agent(Agents.get_agent(agent.id), %{kind: "reviewer"})
    Kiro.stop(agent.id)
    Chat.handle(run, "/ask Coder please write a file")
    assert_receive {:message, %{author: "Coder", body: body}}, 5_000
    assert body =~ "[deny] echo: please write a file"
    assert body =~ "Denied: Write notes.md. Coder only reads and checks"
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

  test "compacting needs a running session; the next message carries the conversation", %{
    agent: agent,
    run: run
  } do
    assert {:error, :no_session} = Kiro.compact(agent)

    Chat.handle(run, "/ask Coder hi")
    assert_receive {:message, %{author: "Coder"}}, 5_000
    old_port = :sys.get_state(Kiro.whereis(agent.id)).port

    assert :ok = Kiro.compact(Agents.get_agent(agent.id))

    compacted = Agents.get_agent(agent.id)
    assert %{status: "done", activity: "Context compacted"} = compacted
    assert compacted.usage["compacted_from"] == 2.0
    refute Map.has_key?(compacted.usage, "context_pct")
    # A fresh kiro-cli, not the old one.
    refute :sys.get_state(Kiro.whereis(agent.id)).port == old_port

    # The fake Kiro echoes what it's sent: the compacted conversation, then the message.
    Chat.handle(run, "/ask Coder again")

    assert_receive {:message,
                    %{
                      author: "Coder",
                      body: body,
                      meta: %{"compacted_from" => 2.0, "context_pct" => 2.0}
                    }},
                   5_000

    assert body =~ "<conversation-so-far>"
    assert body =~ "[entry e1] Message to Coder:\nhi"
    assert body =~ "[entry e2] Reply from Coder:\necho: hi"
    assert body =~ ~r/<\/conversation-so-far>\n\nagain\z/
    refute Map.has_key?(Agents.get_agent(agent.id).usage, "compacted_from")
  end

  test "/compact compacts the agent and notes what it kept in the chat", %{
    agent: agent,
    run: run
  } do
    Chat.handle(run, "/compact Coder")

    assert_receive {:message, %{body: "Nothing to compact: Coder has no Kiro session running."}},
                   5_000

    Chat.handle(run, "/ask Coder hi")
    assert_receive {:message, %{author: "Coder"}}, 5_000

    Chat.handle(run, "/compact Coder")
    agent_id = agent.id

    assert_receive {:message,
                    %{
                      role: "factory",
                      body:
                        "Coder's conversation was compacted: 0 earlier entries summarized, the last 2 word for word" <>
                          _,
                      meta: %{
                        "agent_id" => ^agent_id,
                        "compaction" => %{"kept" => 2, "auto" => false, "sha256" => sha}
                      }
                    }},
                   5_000

    assert sha =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "a session over the threshold compacts before its next message", %{run: run} do
    # The fake Kiro reports 2% after every reply.
    Application.put_env(:factory, :context, compact_at: 2)
    on_exit(fn -> Application.delete_env(:factory, :context) end)

    Chat.handle(run, "/ask Coder first")
    assert_receive {:message, %{author: "Coder", body: "echo: first"}}, 5_000

    Chat.handle(run, "/ask Coder second")

    assert_receive {:message,
                    %{
                      body: "Coder's conversation was compacted:" <> note,
                      meta: %{"compaction" => %{"auto" => true}}
                    }},
                   5_000

    assert note =~ "Its context was 2% full (compacting starts at 2%)."
    assert_receive {:message, %{author: "Coder", body: body}}, 5_000
    assert body =~ "[entry e1] Message to Coder:\nfirst"
    assert String.ends_with?(body, "second")
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

  test "a chat's agent works in the chat's project folder, moving when the chat does", %{
    agent: agent,
    run: run
  } do
    Chat.handle(run, "/ask Coder hi")
    assert_receive {:message, %{author: "Coder"}}, 5_000
    assert :sys.get_state(Kiro.whereis(agent.id)).workdir == Kiro.config(:workspace)

    dir = File.cwd!()
    {:ok, other} = Runs.create_run()
    {:ok, other} = Runs.update_run(other, %{settings: %{"project_dir" => dir}})
    Runs.subscribe(other.id)
    Chat.handle(other, "/ask Coder hi again")
    assert_receive {:message, %{author: "Coder", run_id: run_id}}, 5_000
    assert run_id == other.id
    assert :sys.get_state(Kiro.whereis(agent.id)).workdir == dir
  end
end
