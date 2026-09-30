defmodule Factory.SpecsConcurrencyTest do
  # Not async: this commits real rows outside the sandbox (unboxed) to test the run
  # lock, and they'd be visible to tests running at the same time.
  use Factory.DataCase, async: false
  alias Factory.Runs

  test "concurrent spec attachments replace a complete task set under the parent lock" do
    parent = self()

    # The run is committed for real, so it's removed whatever happens after this,
    # including a failed assertion below (a run left behind would show in other tests).
    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from r in Runs.Run, where: r.title == "Concurrent attachments")
      end)
    end)

    {creator, creator_ref} = unboxed_task(fn -> Runs.create_run("Concurrent attachments") end)
    assert_receive {:unboxed, ^creator, {:ok, run}}, 5_000
    assert_receive {:DOWN, ^creator_ref, :process, ^creator, :normal}

    {first, first_ref} =
      unboxed_task(fn ->
        Repo.transact(fn ->
          {:ok, _} =
            Runs.attach_spec(run, [{"tasks.md", "1. First"}], [%{ref: "1", title: "First"}])

          send(parent, :first_attached)

          receive do
            :commit -> {:ok, :committed}
          end
        end)
      end)

    assert_receive :first_attached, 5_000
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:factory, :repo, :query],
      fn _, _, metadata, parent ->
        if Process.get(:attachment_writer) == :second and
             metadata.query =~ ~s(DELETE FROM "tasks") do
          send(parent, :second_deleted_tasks)
        end
      end,
      parent
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {second, second_ref} =
      unboxed_task(fn ->
        Process.put(:attachment_writer, :second)
        send(parent, :second_started)
        Runs.attach_spec(run, [{"tasks.md", "1. Second"}], [%{ref: "1", title: "Second"}])
      end)

    assert_receive :second_started, 5_000
    refute_receive :second_deleted_tasks, 100
    send(first, :commit)
    assert_receive {:unboxed, ^first, {:ok, :committed}}, 5_000
    assert_receive {:DOWN, ^first_ref, :process, ^first, :normal}
    assert_receive {:unboxed, ^second, {:ok, attached}}, 5_000
    assert_receive {:DOWN, ^second_ref, :process, ^second, :normal}
    assert [%{title: "Second", position: 1}] = attached.tasks
    assert attached.spec =~ "1. Second"
  end

  defp unboxed_task(fun) do
    parent = self()

    worker =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             receive do
               :start ->
                 result = Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
                 send(parent, {:unboxed, self(), result})
             end
           end},
          id: make_ref()
        )
      )

    ref = Process.monitor(worker)
    send(worker, :start)
    {worker, ref}
  end
end
