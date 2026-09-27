defmodule Factory.Runs do
  @moduledoc "Runs: a chat with the factory, the spec attached to it and the tasks read from that spec."
  import Ecto.Query
  alias Factory.Repo
  alias Factory.Runs.{Run, Task, Message}

  @doc "Subscribes to `{:runs_changed}` for the run list."
  def subscribe, do: Phoenix.PubSub.subscribe(Factory.PubSub, "runs")

  @doc "Subscribes to `{:message, message}` and `{:run_updated, run}` for one run."
  def subscribe(run_id), do: Phoenix.PubSub.subscribe(Factory.PubSub, "run:#{run_id}")

  def unsubscribe(run_id), do: Phoenix.PubSub.unsubscribe(Factory.PubSub, "run:#{run_id}")

  defp broadcast(topic, msg), do: Phoenix.PubSub.broadcast(Factory.PubSub, topic, msg)

  def list_runs do
    Repo.all(from r in Run, order_by: [desc: r.updated_at, desc: r.id], preload: :tasks)
  end

  def count_active,
    do: Repo.aggregate(from(r in Run, where: r.status in ["queued", "running"]), :count)

  def get_run(id), do: Run |> Repo.get(id) |> Repo.preload(:tasks)

  def create_run(title \\ "New chat") do
    with {:ok, run} <- %Run{} |> Run.changeset(%{title: title}) |> Repo.insert() do
      broadcast("runs", {:runs_changed})
      {:ok, Repo.preload(run, :tasks)}
    end
  end

  def update_run(%Run{} = run, attrs) do
    with {:ok, run} <- run |> Run.changeset(attrs) |> Repo.update(force: true) do
      run = Repo.preload(run, :tasks, force: true)
      broadcast("run:#{run.id}", {:run_updated, run})
      broadcast("runs", {:runs_changed})
      {:ok, run}
    end
  end

  def delete_run(%Run{} = run) do
    with {:ok, _} <- Repo.delete(run), do: broadcast("runs", {:runs_changed})
  end

  @doc "Stores the spec files and replaces the run's tasks with the ones found in them."
  def attach_spec(%Run{} = run, files, tasks) do
    Repo.transact(fn ->
      Repo.delete_all(from t in Task, where: t.run_id == ^run.id)
      now = DateTime.utc_now(:second)

      rows =
        for {task, i} <- Enum.with_index(tasks, 1) do
          %{
            run_id: run.id,
            position: i,
            ref: task.ref,
            title: task.title,
            inserted_at: now,
            updated_at: now
          }
        end

      Repo.insert_all(Task, rows)

      spec =
        Enum.map_join(files, "\n\n", fn {name, content} ->
          "<!-- file: #{name} -->\n#{content}"
        end)

      names = Enum.map(files, &elem(&1, 0))
      title = if run.title == "New chat", do: spec_title(files), else: run.title
      update_run(run, %{spec: spec, spec_files: names, title: title})
    end)
  end

  # The first markdown heading in the spec, or the first file name.
  defp spec_title([{name, _} | _] = files) do
    Enum.find_value(files, Path.rootname(name), fn {_, content} ->
      case Regex.run(~r/^#\s+(.+)$/m, content) do
        [_, heading] -> heading |> String.trim() |> String.slice(0, 80)
        _ -> nil
      end
    end)
  end

  def list_messages(run_id) do
    Repo.all(from m in Message, where: m.run_id == ^run_id, order_by: m.id)
  end

  def post(%Run{} = run, role, body, opts \\ []) do
    message =
      Repo.insert!(%Message{
        run_id: run.id,
        role: role,
        body: body,
        attachments: Keyword.get(opts, :attachments, []),
        actions: Keyword.get(opts, :actions, [])
      })

    broadcast("run:#{run.id}", {:message, message})
    message
  end
end
