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

  test "denying permission cancels when Kiro offers only allow or no options", %{
    agent: agent,
    run: run
  } do
    {:ok, agent} = Agents.update_agent(agent, %{kind: "reviewer"})

    for options <- ["allow-only", "no-options"] do
      text = "write [test:#{options}]"
      assert {:ok, "[cancelled] echo: " <> ^text} = Kiro.ask(text)
      assert :ok = Kiro.prompt(agent, run.id, text)
      assert_receive {:message, %{author: "Coder", body: body}}, 5_000
      assert body =~ "[cancelled] echo: #{text}"
      assert body =~ "Denied: Write notes.md"
      state = :sys.get_state(Kiro.whereis(agent.id))
      assert Enum.any?(state.log, &(&1.kind == :tool and &1.outcome == "denied"))
    end
  end

  test "an allowed tool with no allow option is cancelled and logged as denied", %{
    agent: agent,
    run: run
  } do
    assert {:ok, "[cancelled] echo: write [test:reject-only]"} =
             Kiro.ask("write [test:reject-only]", allow: ["edit"])

    assert :ok = Kiro.prompt(agent, run.id, "write [test:reject-only]")
    assert_receive {:message, %{author: "Coder", body: body}}, 5_000
    assert body =~ "[cancelled]"
    assert body =~ "Denied: Write notes.md"
    state = :sys.get_state(Kiro.whereis(agent.id))
    assert Enum.any?(state.log, &(&1.kind == :tool and &1.outcome == "denied"))
  end

  @tag :tmp_dir
  test "concurrent prompts accept jobs for only the session's folder", %{
    agent: agent,
    run: run,
    tmp_dir: dir
  } do
    {:ok, other} = Runs.create_run()
    {:ok, other} = Runs.update_run(other, %{settings: %{"project_dir" => dir}})
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    tasks =
      for run <- List.duplicate(run, 4) ++ List.duplicate(other, 4) do
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> {Kiro.workdir(run), Kiro.prompt(agent, run.id, "[test:wait]")}
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _}, 5_000)
    for task <- tasks, do: send(task.pid, :go)
    results = Enum.map(tasks, &Task.await(&1, 5_000))
    state = :sys.get_state(Kiro.whereis(agent.id))

    for {dir, result} <- results do
      assert result == if(dir == state.workdir, do: :ok, else: {:error, :busy})
    end

    assert Enum.count(results, &(elem(&1, 1) == :ok)) == 4
  end

  @tag :tmp_dir
  test "enqueue rejects a run belonging to a different folder", %{
    agent: agent,
    run: run,
    tmp_dir: dir
  } do
    pid = start_supervised!({Kiro.Session, {agent.id, dir}})
    assert {:error, :busy} = Kiro.Session.prompt(pid, agent, run.id, "wrong project")
    assert %{turn: nil, queue: []} = :sys.get_state(pid)
  end

  test "timeout restarts the transport and stale traffic cannot finish the next turn", %{
    agent: agent,
    run: run
  } do
    assert :ok = Kiro.prompt(agent, run.id, "first [test:wait]")
    assert_receive {:agent_stream, %{text: "waiting"}}, 5_000
    pid = Kiro.whereis(agent.id)
    old = :sys.get_state(pid)
    assert :ok = Kiro.prompt(agent, run.id, "second [test:wait]")

    send(pid, {:request_timeout, old.turn.request_id})
    assert_receive {:message, %{author: "Coder", body: "waiting"}}, 5_000
    assert_receive {:agent_stream, %{text: "waiting"}}, 5_000
    current = :sys.get_state(pid)
    refute current.port == old.port
    refute current.turn.request_id == old.turn.request_id

    late_chunk = %{
      method: "session/update",
      params: %{
        sessionId: old.session_id,
        update: %{sessionUpdate: "agent_message_chunk", content: %{type: "text", text: "late"}}
      }
    }

    late_response = %{id: old.turn.request_id, result: %{stopReason: "end_turn"}}
    send_rpc(pid, old.port, late_chunk)
    send_rpc(pid, old.port, late_response)
    send_rpc(pid, current.port, late_response)
    send_rpc(pid, current.port, %{id: old.turn.request_id, error: %{message: "late error"}})
    send_rpc(pid, current.port, late_chunk)
    send(pid, {:request_timeout, old.turn.request_id})
    assert :sys.get_state(pid).turn.request_id == current.turn.request_id
    assert :sys.get_state(pid).turn.text == "waiting"

    send_rpc(pid, current.port, %{id: current.turn.request_id, result: %{stopReason: "end_turn"}})
    assert_receive {:message, %{author: "Coder", body: "waiting", meta: meta}}, 5_000
    assert meta["stop_reason"] == "end_turn"
    assert Kiro.Session.idle?(pid)
    assert Agents.get_agent(agent.id).usage["turns"] == 2
  end

  test "a prompt deadline fires and the queued job runs in the restarted session", %{
    agent: agent,
    run: run
  } do
    configure(:kiro, prompt_timeout: 200)
    assert :ok = Kiro.prompt(agent, run.id, "[test:wait]")
    assert :ok = Kiro.prompt(agent, run.id, "next")
    assert_receive {:message, %{author: "Coder", body: "waiting"}}, 5_000
    assert_receive {:message, %{author: "Coder", body: body}}, 5_000
    assert String.ends_with?(body, "\n\nnext")
    assert body =~ "Stopped after waiting"
    assert Kiro.Session.idle?(Kiro.whereis(agent.id))
  end

  for method <- ["initialize", "session/new", "session/set_config_option"] do
    @tag :tmp_dir
    test "#{method} has a deadline and fails all waiting jobs", %{
      agent: agent,
      run: run,
      tmp_dir: dir
    } do
      method = unquote(method)
      configure(:kiro, rpc_timeout: 500)
      File.write!(Path.join(dir, ".fake-kiro-stall"), method)
      {:ok, run} = Runs.update_run(run, %{settings: %{"project_dir" => dir}})
      agent = %{agent | model: "claude-haiku-4.5"}
      assert :ok = Kiro.prompt(agent, run.id, "first")
      pid = Kiro.whereis(agent.id)
      ref = Process.monitor(pid)
      assert :ok = Kiro.prompt(agent, run.id, "second")

      for _ <- 1..2 do
        assert_receive {:message, %{body: body}}, 5_000
        assert body == "Coder couldn't start: Kiro didn't answer #{method} before its deadline."
      end

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
      assert Agents.get_agent(agent.id).status == "error"
      assert Kiro.whereis(agent.id) == nil
    end
  end

  test "completed RPC deadlines cannot fail a later turn", %{agent: agent, run: run} do
    assert :ok = Kiro.prompt(agent, run.id, "[test:wait]")
    assert_receive {:agent_stream, %{text: "waiting"}}, 5_000
    pid = Kiro.whereis(agent.id)
    state = :sys.get_state(pid)
    assert map_size(state.pending) == 1

    for id <- 1..(state.turn.request_id - 1), do: send(pid, {:request_timeout, id})
    assert :sys.get_state(pid).turn.request_id == state.turn.request_id
  end

  test "the resident log keeps a bounded suffix and reports dropped entries", %{
    agent: agent,
    run: run
  } do
    configure(:context, max_log_entries: 4)

    for n <- 1..4 do
      assert :ok = Kiro.prompt(agent, run.id, "turn #{n}")
      assert_receive {:message, %{author: "Coder"}}, 5_000
    end

    state = :sys.get_state(Kiro.whereis(agent.id))
    assert Enum.map(state.log, & &1.id) == ["e8", "e7", "e6", "e5"]
    assert state.log_dropped == 4
    assert :ok = Kiro.compact(agent)
    assert :ok = Kiro.prompt(agent, run.id, "next")
    assert_receive {:message, %{author: "Coder", body: body}}, 5_000
    assert body =~ "[omitted 4 older log entries due to the session retention limit]"
    assert body =~ "turn 4"
    refute body =~ "turn 1"
  end

  test "the resident log also enforces its byte limit", %{agent: agent, run: run} do
    configure(:context, max_log_bytes: 1600)

    for _ <- 1..3 do
      assert :ok = Kiro.prompt(agent, run.id, String.duplicate("x", 500))
      assert_receive {:message, %{author: "Coder"}}, 5_000
    end

    state = :sys.get_state(Kiro.whereis(agent.id))
    assert state.log != []
    assert state.log_dropped > 0
    assert Enum.sum(Enum.map(state.log, &(:erlang.external_size(&1) + 8))) <= 1600
  end

  defp send_rpc(pid, port, message),
    do: send(pid, {port, {:data, {:eol, JSON.encode!(message)}}})

  defp configure(key, values) do
    previous = Application.get_env(:factory, key)
    Application.put_env(:factory, key, Keyword.merge(previous || [], values))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:factory, key, previous),
        else: Application.delete_env(:factory, key)
    end)
  end
end
