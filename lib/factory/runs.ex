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

  @doc "Subscribes to `{:active_runs_changed}`: a run was made, removed or changed status."
  def subscribe_active, do: Phoenix.PubSub.subscribe(Factory.PubSub, "runs:active")

  defp broadcast(topic, msg), do: Phoenix.PubSub.broadcast(Factory.PubSub, topic, msg)

  @doc "The latest runs, newest first, with their tasks: `limit` of them (default 30)."
  def list_runs(limit \\ 30) do
    Repo.all(
      from r in Run, order_by: [desc: r.updated_at, desc: r.id], limit: ^limit, preload: :tasks
    )
  end

  @doc "Runs with their usage totals, fetched together rather than once per run."
  def list_runs_with_usage do
    totals =
      from e in Factory.Usage.Event,
        group_by: e.run_id,
        select: %{
          run_id: e.run_id,
          credits: sum(e.credits),
          tokens: type(sum(e.input_tokens + e.output_tokens), :integer),
          calls: count(e.id)
        }

    Repo.all(
      from r in Run,
        left_join: t in subquery(totals),
        on: t.run_id == r.id,
        order_by: [desc: r.updated_at, desc: r.id],
        preload: [:tasks, :spec_doc],
        select:
          {r,
           %{
             credits: coalesce(t.credits, 0.0),
             tokens: coalesce(t.tokens, 0),
             calls: coalesce(t.calls, 0)
           }}
    )
  end

  def count_active,
    do: Repo.aggregate(from(r in Run, where: r.status in ["queued", "running"]), :count)

  def get_run(id), do: Run |> Repo.get(id) |> Repo.preload(:tasks)

  @doc "Reads the latest run under a row lock and applies a transactional callback."
  def with_locked_run(id, fun) do
    Repo.transact(fn ->
      case Repo.one(from r in Run, where: r.id == ^id, lock: "FOR UPDATE") do
        nil -> {:error, :not_found}
        run -> fun.(Repo.preload(run, :tasks))
      end
    end)
  end

  def create_run(title \\ "New run") do
    with {:ok, run} <- %Run{} |> Run.changeset(%{title: title}) |> Repo.insert() do
      broadcast("runs", {:runs_changed})
      {:ok, Repo.preload(run, :tasks)}
    end
  end

  # Empty runs: plain chats not started, with no messages, no tasks and no spec of
  # their own yet (a spec written on the Spec page keeps its run).
  defp empty_runs do
    from r in Run,
      as: :run,
      where: is_nil(r.kind) and r.status == "draft" and is_nil(r.spec_id),
      where: not exists(from m in Message, where: m.run_id == parent_as(:run).id),
      where: not exists(from t in Task, where: t.run_id == parent_as(:run).id)
  end

  @doc "The latest empty run (nothing said, no tasks, no spec), to use instead of making another."
  def latest_empty do
    Repo.one(from r in empty_runs(), order_by: [desc: r.updated_at, desc: r.id], limit: 1)
    |> then(&(&1 && Repo.preload(&1, :tasks)))
  end

  @doc "Deletes empty runs not touched for `minutes`. Returns how many."
  def prune_empty(minutes \\ 60) do
    cutoff = DateTime.add(DateTime.utc_now(), -minutes * 60)
    {n, _} = Repo.delete_all(from r in empty_runs(), where: r.updated_at < ^cutoff)
    if n > 0, do: broadcast("runs", {:runs_changed})
    n
  end

  @doc """
  A name for a new run until it gets a better one: the project folder and the day,
  e.g. "shop · 28 Sep", numbered when that's taken.
  """
  def default_title(project_dir) do
    project = if project_dir in [nil, ""], do: "New run", else: Path.basename(project_dir)
    base = "#{project} · #{Calendar.strftime(Date.utc_today(), "%-d %b")}"
    taken = Repo.all(from r in Run, where: like(r.title, ^"#{base}%"), select: r.title)

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn
      1 -> if base not in taken, do: base
      n -> if "#{base} (#{n})" not in taken, do: "#{base} (#{n})"
    end)
  end

  def update_run(%Run{} = run, attrs) do
    old_status = run.status

    with {:ok, run} <- run |> Run.changeset(attrs) |> Repo.update(force: true) do
      run = Repo.preload(run, :tasks, force: true)
      broadcast("run:#{run.id}", {:run_updated, run})
      broadcast("runs", {:runs_changed})
      if run.status != old_status, do: broadcast("runs:active", {:active_runs_changed})
      {:ok, run}
    end
  end

  @doc """
  Marks these tasks (ids) of the run done and returns the run with its tasks. Call
  `tasks_changed/1` with it once any transaction around this has committed.
  """
  def mark_tasks_done(%Run{} = run, task_ids) do
    now = DateTime.utc_now(:second)

    Repo.update_all(from(t in Task, where: t.run_id == ^run.id and t.id in ^task_ids),
      set: [status: "done", updated_at: now]
    )

    Repo.preload(run, :tasks, force: true)
  end

  @doc "Tells the run's pages its tasks changed (see `mark_tasks_done/2`)."
  def tasks_changed(%Run{} = run) do
    broadcast("run:#{run.id}", {:run_updated, run})
    broadcast("runs", {:runs_changed})
  end

  @doc """
  Stores the spec files and replaces the run's tasks with the ones found in them. With
  `keep_status: true`, tasks with the same title keep their status.
  """
  def attach_spec(%Run{} = run, files, tasks, opts \\ []) do
    with_locked_run(run.id, fn run ->
      # A run already under way keeps what's done: a task with the same title keeps
      # its status (`keep_status: true`, when its plan changes after the start).
      statuses =
        if opts[:keep_status],
          do: Map.new(run.tasks, &{&1.title, &1.status}),
          else: %{}

      Repo.delete_all(from t in Task, where: t.run_id == ^run.id)
      now = DateTime.utc_now(:second)

      rows =
        for {task, i} <- Enum.with_index(tasks, 1) do
          %{
            run_id: run.id,
            position: i,
            ref: task.ref,
            title: task.title,
            status: Map.get(statuses, task.title, "pending"),
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
      title = if run.title in ["New run", "New chat"], do: spec_title(files), else: run.title
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

  @doc "Totals of the agent replies in a run: how many turns and how many credits."
  def usage(run_id) do
    %{turns: turns, credits: credits} =
      Repo.one(
        from m in Message,
          where: m.run_id == ^run_id and not is_nil(m.author),
          select: %{
            turns: count(m.id),
            credits: coalesce(sum(fragment("(?->>'credits')::float", m.meta)), 0.0)
          }
      )

    %{turns: turns, credits: credits}
  end

  @doc "How many messages a run has from `role`."
  def count_messages(run_id, role),
    do: Repo.aggregate(from(m in Message, where: m.run_id == ^run_id and m.role == ^role), :count)

  @doc "A run's latest `limit` messages, oldest first."
  def recent_messages(run_id, limit) do
    from(m in Message, where: m.run_id == ^run_id, order_by: [desc: m.id], limit: ^limit)
    |> Repo.all()
    |> Enum.reverse()
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
        actions: Keyword.get(opts, :actions, []),
        author: Keyword.get(opts, :author),
        meta: Keyword.get(opts, :meta, %{})
      })

    broadcast("run:#{run.id}", {:message, message})
    message
  end
end
