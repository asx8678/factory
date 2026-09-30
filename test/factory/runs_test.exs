defmodule Factory.RunsTest do
  use Factory.DataCase, async: true
  alias Factory.{Runs, Specs}

  defp age(run, minutes) do
    at = DateTime.add(DateTime.utc_now(:second), -minutes * 60)
    Repo.update_all(from(r in Runs.Run, where: r.id == ^run.id), set: [updated_at: at])
  end

  test "pruning removes stale empty chats but keeps one that has a spec" do
    {:ok, empty} = Runs.create_run()
    {:ok, planned} = Runs.create_run()
    # Opening the Spec page from a fresh chat gives the run its spec.
    _spec = Specs.for_run(planned)
    age(empty, 90)
    age(planned, 90)
    planned_id = planned.id

    # Other tests may commit runs meanwhile, so check these two, not a total.
    assert Runs.prune_empty() >= 1
    assert Runs.get_run(empty.id) == nil
    assert %{spec_id: id} = Runs.get_run(planned.id)
    assert is_integer(id)
    refute match?(%{id: ^planned_id}, Runs.latest_empty())
  end

  test "usage sums the credits of the agents' replies" do
    {:ok, run} = Runs.create_run()
    Runs.post(run, "user", "hi")
    Runs.post(run, "factory", "one", author: "Coder", meta: %{"credits" => 0.5})
    Runs.post(run, "factory", "two", author: "Coder", meta: %{})
    Runs.post(run, "factory", "note")
    assert Runs.usage(run.id) == %{turns: 2, credits: 0.5}
  end

  test "the chat's run list is bounded, newest first; recent messages are the latest" do
    for i <- 1..4, do: {:ok, _} = Runs.create_run("Run #{i}")
    assert [%{title: "Run 4"}, %{title: "Run 3"}] = Runs.list_runs(2)

    {:ok, run} = Runs.create_run()
    for i <- 1..5, do: Runs.post(run, "user", "m#{i}")
    assert Enum.map(Runs.recent_messages(run.id, 2), & &1.body) == ["m4", "m5"]
    assert Runs.count_messages(run.id, "user") == 5
  end
end
