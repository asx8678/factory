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

  # Broadcasts made inside a transaction wait in the process until it commits.
  @pending :factory_pending_broadcasts

  @doc """
  Broadcasts `msg` on Factory's PubSub topic. Inside a transaction (`transact/1`,
  `with_locked_run/2`) it waits until the transaction has committed, and is dropped if
  it rolls back, so a page never hears of a change that isn't there.
  """
  def broadcast(topic, msg) do
    if Repo.in_transaction?() do
      Process.put(@pending, [{topic, msg} | Process.get(@pending, [])])
      :ok
    else
      Phoenix.PubSub.broadcast(Factory.PubSub, topic, msg)
    end
  end

  @doc """
  `Repo.transact/1`, then the broadcasts made in it (`broadcast/2`), each once, when it
  committed. Inside another transaction it only runs `fun`: the outer one broadcasts.
  """
  def transact(fun) do
    if Repo.in_transaction?() do
      Repo.transact(fun)
    else
      Process.delete(@pending)

      try do
        result = Repo.transact(fun)
        if match?({:ok, _}, result), do: flush_broadcasts()
        result
      after
        Process.delete(@pending)
      end
    end
  end

  defp flush_broadcasts do
    for {topic, msg} <- Process.get(@pending, []) |> Enum.reverse() |> Enum.uniq(),
        do: Phoenix.PubSub.broadcast(Factory.PubSub, topic, msg)

    :ok
  end

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

    # A line per run: not its description, spec or progress, which can be large (a
    # troubleshooting run's description is the logs pasted into it).
    tasks = from t in Task, order_by: t.position, select: struct(t, [:id, :run_id, :status])
    spec = from s in Factory.Specs.Spec, select: struct(s, [:id, :name])

    Repo.all(
      from r in Run,
        left_join: t in subquery(totals),
        on: t.run_id == r.id,
        order_by: [desc: r.updated_at, desc: r.id],
        preload: [tasks: ^tasks, spec_doc: ^spec],
        select:
          {struct(r, [:id, :kind, :title, :status, :spec_id, :inserted_at, :updated_at]),
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

  @doc """
  Reads the latest run under a row lock and applies a transactional callback
  (`transact/1`: what it broadcasts goes out once the transaction has committed).
  """
  def with_locked_run(id, fun) do
    transact(fn ->
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

  @doc """
  The latest review of the repository in `dir` that nothing has been said in yet, to
  open again rather than make another (a repository cloned to review twice).
  """
  def unused_review(dir) do
    Repo.one(
      from r in Run,
        as: :run,
        where: r.kind == "review" and r.status == "draft",
        where: fragment("?->>'project_dir' = ?", r.settings, ^dir),
        where: not exists(from m in Message, where: m.run_id == parent_as(:run).id),
        order_by: [desc: r.id],
        limit: 1
    )
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

  @doc """
  Changes a run and tells its pages (`tasks_changed/2`). Inside a transaction the pages
  hear of it once it has committed (`broadcast/2`).
  """
  def update_run(%Run{} = run, attrs) do
    old_status = run.status

    with {:ok, run} <- run |> Run.changeset(attrs) |> Repo.update(force: true) do
      run = Repo.preload(run, :tasks, force: true)
      tasks_changed(run, status_changed: run.status != old_status)
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

  @doc "Opens tasks again (by id), e.g. ones that failed verification."
  def reopen_tasks(%Run{} = run, task_ids) do
    now = DateTime.utc_now(:second)

    Repo.update_all(from(t in Task, where: t.run_id == ^run.id and t.id in ^task_ids),
      set: [status: "pending", updated_at: now]
    )

    Repo.preload(run, :tasks, force: true)
  end

  @doc """
  Tells the run's pages the run or its tasks changed (see `mark_tasks_done/2`, which
  doesn't). Inside a transaction they hear of it once it has committed (`broadcast/2`).
  With `status_changed: true` the pages counting active runs hear of it too.
  """
  def tasks_changed(%Run{} = run, opts \\ []) do
    broadcast("run:#{run.id}", {:run_updated, run})
    broadcast("runs", {:runs_changed})
    if opts[:status_changed], do: broadcast("runs:active", {:active_runs_changed})
    :ok
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
      Factory.Text.first_heading(content)
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

  @doc """
  Changes a message's meta with `fun` and tells the chat, which shows it again (a
  question answered or expired).
  """
  def update_message_meta(message_id, fun) do
    case Repo.get(Message, message_id) do
      nil ->
        nil

      message ->
        message = message |> Ecto.Changeset.change(meta: fun.(message.meta)) |> Repo.update!()
        broadcast("run:#{message.run_id}", {:message, message})
        message
    end
  end

  @doc """
  Posts a message to the run's chat and tells the chat (`broadcast/2`). Returns the
  message, or `{:error, :gone}` when the run no longer exists (pruned, or deleted
  meanwhile) rather than raising.
  """
  def post(%Run{} = run, role, body, opts \\ []) do
    result =
      %Message{
        run_id: run.id,
        role: role,
        body: body,
        attachments: Keyword.get(opts, :attachments, []),
        actions: Keyword.get(opts, :actions, []),
        author: Keyword.get(opts, :author),
        meta: Keyword.get(opts, :meta, %{})
      }
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.foreign_key_constraint(:run_id)
      |> Repo.insert()

    case result do
      {:ok, message} ->
        broadcast("run:#{run.id}", {:message, message})
        message

      {:error, _changeset} ->
        {:error, :gone}
    end
  end
end
