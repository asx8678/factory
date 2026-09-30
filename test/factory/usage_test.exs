defmodule Factory.UsageTest do
  use Factory.DataCase, async: false
  alias Factory.{Agents, Runs, Specs, Usage, Workflows}

  setup tags do
    previous = Application.get_env(:factory, :timezone)
    Application.put_env(:factory, :timezone, tags[:timezone] || "UTC")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:factory, :timezone, previous),
        else: Application.delete_env(:factory, :timezone)
    end)

    {:ok, run} = Runs.create_run("Fix login")
    {:ok, spec} = Specs.create_spec("CSV export")
    %{run: run, spec: spec}
  end

  test "calls add up by run, spec, day and kind of work", %{run: run, spec: spec} do
    {:ok, _} =
      Usage.record(%{
        source: "agent_turn",
        run_id: run.id,
        credits: 0.5,
        input_tokens: 100,
        output_tokens: 50
      })

    {:ok, _} =
      Usage.record(%{
        source: "agent_turn",
        run_id: run.id,
        credits: 0.25,
        input_tokens: 10,
        output_tokens: 10
      })

    {:ok, _} =
      Usage.record(%{source: "review", spec_id: spec.id, credits: 1.0, input_tokens: 400})

    {:ok, _} = Usage.record(%{source: "draft_task", spec_id: spec.id, credits: 0.1})

    assert %{credits: 0.75, tokens: 170, calls: 2} = Usage.totals({:run, run.id})
    assert %{credits: 1.1, calls: 2} = Usage.totals({:spec, spec.id})
    assert %{calls: 4} = Usage.totals(:today)

    today = Usage.today()
    days = Usage.days(today)
    assert length(days) == Date.days_in_month(today)
    assert %{calls: 4, credits: 1.85} = Enum.find(days, &(&1.date == today))

    # Sessions: most used first by default, least used or filtered on request.
    assert [%{title: "CSV export", kind: "Spec"}, %{title: "Fix login", kind: "Chat"}] =
             Usage.sessions(today)

    assert [%{title: "Fix login"}, %{title: "CSV export"}] =
             Usage.sessions(today, %{"sort" => "least"})

    assert [%{title: "CSV export", calls: 1, by_source: %{"review" => 1.0}}] =
             Usage.sessions(today, %{"source" => "review"})

    assert [%{source: "draft_task"}, %{source: "review"}] = Usage.calls({:spec, spec.id}, today)
    assert [%{local_at: %NaiveDateTime{}} | _] = Usage.calls({:run, run.id}, {:month, today})
  end

  test "a session key round-trips through a URL parameter", %{run: run} do
    assert run.id |> then(&{:run, &1}) |> Usage.key_to_param() |> Usage.param_to_key() ==
             {:run, run.id}

    assert Usage.param_to_key("other") == :other
    assert Usage.param_to_key("nonsense") == nil
  end

  @tag timezone: "Europe/Warsaw"
  test "day ranges include local midnight and exclude the next across both DST changes" do
    for {day, first, next} <- [
          {~D[2026-03-29], ~U[2026-03-28 23:00:00Z], ~U[2026-03-29 22:00:00Z]},
          {~D[2026-10-25], ~U[2026-10-24 22:00:00Z], ~U[2026-10-25 23:00:00Z]}
        ] do
      usage_at(DateTime.add(first, -1, :microsecond))
      start = usage_at(first)
      finish = usage_at(DateTime.add(next, -1, :microsecond))
      usage_at(next)

      assert [%{calls: 2}] = Usage.sessions(day)
      assert Enum.map(Usage.calls(:other, day), & &1.id) == [finish.id, start.id]
      assert %{calls: 2} = Enum.find(Usage.days(day), &(&1.date == day))
    end
  end

  @tag timezone: "Europe/Warsaw"
  test "month boundaries use each endpoint's UTC offset" do
    usage_at(~U[2026-02-28 22:59:59.999999Z])
    first = usage_at(~U[2026-02-28 23:00:00Z])
    last = usage_at(~U[2026-03-31 21:59:59.999999Z])
    usage_at(~U[2026-03-31 22:00:00Z])

    month = {:month, ~D[2026-03-15]}
    assert %{calls: 2} = Usage.totals(month)
    assert [%{calls: 2}] = Usage.sessions(month)
    assert Enum.map(Usage.calls(:other, month), & &1.id) == [last.id, first.id]
  end

  test "date filters keep the indexed timestamp bare in SQL" do
    observe_queries()
    Usage.totals(:today)
    assert_receive {:query, "usage_events", sql}
    [_, predicate] = String.split(sql, "WHERE", parts: 2)
    assert predicate =~ ~s(."inserted_at" >=)
    assert predicate =~ ~s(."inserted_at" <)
    refute predicate =~ "AT TIME ZONE"
  end

  test "usage events have an agent index" do
    assert %{rows: [[true]]} =
             Repo.query!("""
             SELECT EXISTS (
               SELECT 1 FROM pg_indexes
               WHERE tablename = 'usage_events'
                 AND indexname = 'usage_events_agent_id_index'
             )
             """)
  end

  test "activity and usage broadcasts do not trigger a structural graph refresh" do
    {:ok, workflow} = Workflows.create("Activity")
    {:ok, agent} = Agents.create_agent(%{name: "Reader", workflow_id: workflow.id})
    Agents.subscribe()
    id = agent.id

    run_supervised(fn -> Agents.set_activity(id, "running", "Reading") end)
    assert_receive {:agent_activity, %{id: ^id, status: "running", activity: "Reading"}}
    refute_receive {:graph_changed}

    run_supervised(fn -> Agents.record_usage(id, %{"credits" => 2.0}) end)
    assert_receive {:agent_activity, %{id: ^id, usage: %{"credits" => 2.0}}}
    refute_receive {:graph_changed}

    run_supervised(fn -> Agents.update_agent(agent, %{name: "Writer"}) end)
    assert_receive {:graph_changed}
  end

  test "workflow subscriptions receive only their workflow's activity" do
    {:ok, workflow} = Workflows.create("Activity")
    {:ok, other} = Workflows.create("Other activity")
    {:ok, agent} = Agents.create_agent(%{name: "Reader", workflow_id: workflow.id})
    {:ok, outsider} = Agents.create_agent(%{name: "Other", workflow_id: other.id})
    Agents.subscribe(workflow.id)

    run_supervised(fn -> Agents.set_activity(outsider.id, "running", "Other work") end)
    refute_receive {:agent_activity, _}

    run_supervised(fn -> Agents.set_activity(agent.id, "running", "Work") end)
    id = agent.id
    assert_receive {:agent_activity, %{id: ^id}}
    refute_receive {:graph_changed}
  end

  test "graph links are restricted to the workflow in SQL" do
    {:ok, workflow} = Workflows.create("Graph")
    {:ok, other} = Workflows.create("Other graph")
    {:ok, a} = Agents.create_agent(%{name: "A", workflow_id: workflow.id})
    {:ok, b} = Agents.create_agent(%{name: "B", workflow_id: workflow.id})
    {:ok, c} = Agents.create_agent(%{name: "C", workflow_id: other.id})
    {:ok, d} = Agents.create_agent(%{name: "D", workflow_id: other.id})
    {:ok, link} = Agents.link(a.id, b.id)
    {:ok, _} = Agents.link(c.id, d.id)
    # Even a legacy cross-workflow link must not point outside this canvas.
    Repo.insert!(%Factory.Agents.Link{source_id: a.id, target_id: c.id})

    observe_queries()
    assert [%{id: id}] = Agents.graph(workflow.id).edges
    assert id == "l#{link.id}"
    assert_receive {:query, "links", sql}
    assert sql =~ "WHERE"
    assert sql =~ ~s(."workflow_id" =)
  end

  test "context severity uses the thresholds exposed for the graph" do
    previous = Application.get_env(:factory, :context)
    Application.put_env(:factory, :context, compact_at: 60)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:factory, :context, previous),
        else: Application.delete_env(:factory, :context)
    end)

    assert %{mid: 36.0, high: 60} = FactoryWeb.Usage.thresholds()
    assert FactoryWeb.Usage.level(35.9) == "low"
    assert FactoryWeb.Usage.level(36) == "mid"
    assert FactoryWeb.Usage.level(59.9) == "mid"
    assert FactoryWeb.Usage.level(60) == "high"
    assert FactoryWeb.Usage.level(nil) == nil
  end

  defp usage_at(timestamp) do
    {microseconds, _precision} = timestamp.microsecond

    Repo.insert!(%Factory.Usage.Event{
      source: "other",
      inserted_at: %{timestamp | microsecond: {microseconds, 6}}
    })
  end

  defp run_supervised(fun) do
    pid = start_supervised!({Task, fun}, id: make_ref())
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}
    assert reason in [:normal, :noproc]
  end

  defp observe_queries do
    id = {__MODULE__, make_ref()}
    :telemetry.attach(id, [:factory, :repo, :query], &__MODULE__.query/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  def query(_event, _measurements, metadata, pid) do
    send(pid, {:query, metadata[:source], metadata.query})
  end

  test "by_source groups a run's credits and calls by kind of work, most first" do
    {:ok, run} = Runs.create_run("Fix login")
    {:ok, other} = Runs.create_run("Other")

    for {source, credits, run_id} <- [
          {"agent_turn", 0.25, run.id},
          {"agent_turn", 0.25, run.id},
          {"review", 1.0, run.id},
          {"review", 9.0, other.id}
        ],
        do: {:ok, _} = Usage.record(%{source: source, credits: credits, run_id: run_id})

    assert Usage.by_source({:run, run.id}) == [{"review", 1.0, 1}, {"agent_turn", 0.5, 2}]
  end
end
