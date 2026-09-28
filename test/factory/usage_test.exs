defmodule Factory.UsageTest do
  use Factory.DataCase, async: true
  alias Factory.{Runs, Specs, Usage}

  setup do
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
end
