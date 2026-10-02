defmodule Factory.Sources do
  @moduledoc """
  Data sources: outside material a workflow's agents work from, next to the project
  folder. Azure DevOps and Git repositories are cloned into a local folder (and
  pulled again with `sync/1`); local folders, instruction files and meta indexes are
  read where they are.

  Each source is a card on the workflow's canvas, attached to agents by arrows. An
  agent gets the enabled, ready sources attached to it in its prompt (see
  `context_for_agent/1`); Kiro gets all of a workflow's sources when it plans a run
  for it (see `context/1`).
  Personal access tokens are never stored: an Azure DevOps source names an
  environment variable, read only while syncing.
  """
  import Ecto.Query, only: [from: 2]
  alias Factory.{Agents, Kiro, Repo}
  alias Factory.Sources.{Link, PageIndex, Source}

  @kinds [
    {"azure_devops", "Azure DevOps repository",
     "Clone a repo from dev.azure.com and keep it in sync."},
    {"git", "Git repository", "Any Git remote: GitHub, GitLab, Bitbucket or your own server."},
    {"folder", "Local folder", "A folder on this machine the agents can read."},
    {"instructions", "Instruction file", "Rules and conventions every agent follows."},
    {"meta_index", "Meta index", "An index file that maps where things are in a set of docs."},
    {"pageindex", "PageIndex",
     "A PageIndex tree of a long document: agents jump to the right section."}
  ]

  @doc "Kinds of source, as `{kind, label, description}`."
  def kinds, do: @kinds

  def label(kind), do: Enum.find_value(@kinds, kind, fn {k, l, _} -> k == kind && l end)

  def list(workflow_id),
    do: Repo.all(from s in Source, where: s.workflow_id == ^workflow_id, order_by: s.id)

  def get(id), do: Repo.get(Source, id)

  def change(%Source{} = source, attrs \\ %{}), do: Source.changeset(source, attrs)

  @doc """
  Adds a source to a workflow, its card below the others left of the agents.
  `"agents"` (ids) attaches it. Repositories start syncing at once unless
  `sync: false` is passed. Inside a transaction, use `sync: false`, then call
  `start_sync/1` on the returned source after the transaction commits.
  """
  def create(workflow_id, attrs, opts \\ []) do
    attrs = stringify(attrs)
    {agent_ids, attrs} = Map.pop(attrs, "agents")

    attrs =
      if attrs["x"],
        do: attrs,
        else: Map.merge(attrs, next_position(workflow_id))

    # The workflow is Factory's choice, never a form field.
    %Source{workflow_id: workflow_id}
    |> Source.changeset(attrs)
    |> Repo.insert()
    |> after_change(fn source ->
      if agent_ids, do: set_agents(source, agent_ids)
      if repo?(source) and Keyword.get(opts, :sync, true), do: start_sync(source)
    end)
  end

  def update(%Source{} = source, attrs) do
    {agent_ids, attrs} = attrs |> stringify() |> Map.pop("agents")

    source
    |> Source.changeset(attrs)
    |> Repo.update()
    |> after_change(fn updated ->
      if agent_ids, do: set_agents(updated, agent_ids)
      if repo?(updated) and updated.config != source.config, do: sync(updated)
    end)
  end

  def toggle(%Source{} = source), do: update(source, %{enabled: !source.enabled})

  @doc "Removes a source, and what Factory keeps for it (a repository's clone, a tree's sections)."
  def delete(%Source{} = source) do
    remove_files(source)
    source |> Repo.delete() |> after_change(fn _ -> :ok end)
  end

  @doc """
  Removes what Factory made for a source under its sources folder: a repository's
  clone, a PageIndex tree's section files. Never the folder or file a source points to,
  which is the person's own. For a source deleted some other way (its workflow's
  deletion), once that has committed.
  """
  def remove_files(%Source{kind: kind} = source)
      when kind in ["azure_devops", "git", "pageindex"] do
    for dir <- own_dirs(source), do: File.rm_rf(dir)
    :persistent_term.erase({__MODULE__, :pageindex, source.id})
    :ok
  end

  def remove_files(%Source{}), do: :ok

  # Attaching sources to agents

  @doc "Ids of the agents a source is attached to."
  def agent_ids(%Source{id: id}),
    do:
      Repo.all(
        from l in Link, where: l.source_id == ^id, select: l.agent_id, order_by: l.agent_id
      )

  @doc "A workflow's attachments, as `[{source_id, agent_id}]`."
  def links(workflow_id) do
    Repo.all(
      from l in Link,
        join: s in Source,
        on: s.id == l.source_id,
        where: s.workflow_id == ^workflow_id,
        select: {l.source_id, l.agent_id},
        order_by: l.id
    )
  end

  @doc "Attaches a source to an agent of the same workflow."
  def attach(%Source{} = source, agent_id) do
    case Agents.get_agent(agent_id) do
      %{kind: "action"} ->
        {:error, :action}

      %{workflow_id: wid} when wid == source.workflow_id ->
        now = DateTime.utc_now(:second)

        Repo.insert_all(
          Link,
          [
            %{source_id: source.id, agent_id: to_int(agent_id), inserted_at: now, updated_at: now}
          ],
          on_conflict: :nothing,
          conflict_target: [:source_id, :agent_id]
        )

        attachments_changed(source)

      _ ->
        {:error, :other_workflow}
    end
  end

  def detach(%Source{} = source, agent_id) do
    agent_id = to_int(agent_id)
    Repo.delete_all(from l in Link, where: l.source_id == ^source.id and l.agent_id == ^agent_id)
    attachments_changed(source)
  end

  @doc "Attaches a source to exactly these agents (ids, of its workflow)."
  def set_agents(%Source{} = source, agent_ids) do
    ids = agent_ids |> Enum.map(&to_int/1) |> MapSet.new()
    allowed = source.workflow_id |> Agents.list_agents() |> MapSet.new(& &1.id)
    wanted = ids |> MapSet.intersection(allowed) |> MapSet.to_list()
    now = DateTime.utc_now(:second)

    Repo.transact(fn ->
      Repo.delete_all(
        from l in Link, where: l.source_id == ^source.id and l.agent_id not in ^wanted
      )

      Repo.insert_all(
        Link,
        for(
          id <- wanted,
          do: %{source_id: source.id, agent_id: id, inserted_at: now, updated_at: now}
        ),
        on_conflict: :nothing,
        conflict_target: [:source_id, :agent_id]
      )

      {:ok, source}
    end)

    attachments_changed(source)
  end

  defp attachments_changed(source) do
    forget_context(source.workflow_id)
    Agents.notify_changed()
    {:ok, source}
  end

  defp to_int(id) when is_integer(id), do: id
  defp to_int(id), do: String.to_integer(to_string(id))

  @doc "Saves where cards were moved: `[%{\"id\" => id, \"x\" => x, \"y\" => y}]`."
  def move(positions) do
    for %{"id" => id, "x" => x, "y" => y} <- positions do
      Repo.update_all(from(s in Source, where: s.id == ^to_int(id)), set: [x: x / 1, y: y / 1])
    end

    :ok
  end

  # Below the workflow's other cards, left of its agents.
  defp next_position(workflow_id) do
    agents = Agents.list_agents(workflow_id)
    sources = list(workflow_id)
    x = if agents == [], do: -320.0, else: Enum.min(Enum.map(agents, & &1.x)) - 320.0

    y =
      cond do
        sources != [] -> Enum.max(Enum.map(sources, & &1.y)) + 110.0
        agents != [] -> Enum.min(Enum.map(agents, & &1.y))
        true -> 0.0
      end

    %{"x" => x, "y" => y}
  end

  defp after_change({:ok, source} = result, then) do
    then.(source)
    forget_context(source.workflow_id)
    Agents.notify_changed()
    result
  end

  defp after_change(error, _then), do: error

  # The workflow's agents get their context again with their next message.
  defp forget_context(workflow_id) do
    for agent <- Agents.list_agents(workflow_id), do: Kiro.forget(agent)
  end

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

  def repo?(%Source{kind: kind}), do: kind in ["azure_devops", "git"]

  # Syncing repositories

  @doc """
  Where a source is on this machine: a repository's clone, or the folder or file given.
  A clone's folder is named by the source's id, so renaming the source keeps it.
  """
  def local_path(%Source{kind: kind} = s) when kind in ["azure_devops", "git"], do: own_dir(s)

  def local_path(%Source{config: config}), do: config["path"] && Path.expand(config["path"])

  # The folder Factory keeps for a source under the sources folder: `<id>`. One made
  # before that was named `<id>-<name as it was then>`, and is still used: the one for
  # the name now if it's there, else any other.
  defp own_dir(%Source{id: id} = s) do
    dir = Path.join(sources_dir(), to_string(id))

    case own_dirs(s) do
      [] -> dir
      dirs -> if dir in dirs, do: dir, else: Enum.find(dirs, hd(dirs), &(&1 == old_dir(s)))
    end
  end

  defp old_dir(%Source{} = s) do
    slug = s.name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
    Path.join(sources_dir(), "#{s.id}-#{slug}")
  end

  # Every folder there that's this source's, in either naming.
  defp own_dirs(%Source{id: id}) do
    case File.ls(sources_dir()) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            name == "#{id}" or String.starts_with?(name, "#{id}-"),
            do: Path.join(sources_dir(), name)

      {:error, _} ->
        []
    end
  end

  defp sources_dir do
    Application.get_env(:factory, :sources_dir) ||
      Path.expand("../../tmp/sources", __DIR__)
  end

  @doc "The URL a repository source is cloned from."
  def remote_url(%Source{kind: "azure_devops", config: c}) do
    enc = &URI.encode(String.trim(&1), fn ch -> URI.char_unreserved?(ch) end)
    "https://dev.azure.com/#{enc.(c["org"])}/#{enc.(c["project"])}/_git/#{enc.(c["repo"])}"
  end

  def remote_url(%Source{kind: "git", config: c}), do: String.trim(c["url"])

  @doc "Clones or pulls a repository source in the background; its status follows."
  def sync(%Source{} = source), do: start_sync(source)

  @doc """
  Starts a repository sync after its source has committed. Returns `{:ok, source}`
  or `{:error, :already_syncing}` when this source already has a sync in progress.
  Non-repository sources are returned unchanged.
  """
  def start_sync(%Source{} = source) do
    if repo?(source) do
      caller = self()
      ref = make_ref()

      with {:ok, pid} <-
             Task.Supervisor.start_child(Factory.TaskSupervisor, fn ->
               # The registration belongs to the worker, so it is released even
               # when the worker crashes. It covers both git and status updates.
               case :global.register_name({__MODULE__, source.id}, self()) do
                 :yes ->
                   monitor = Process.monitor(caller)
                   send(caller, {ref, :started})

                   receive do
                     {^ref, {:ok, source}} ->
                       Process.demonitor(monitor, [:flush])
                       finish_sync(source, git_sync(source))

                     {^ref, _error} ->
                       :ok

                     {:DOWN, ^monitor, :process, ^caller, _reason} ->
                       :ok
                   end

                 :no ->
                   send(caller, {ref, :already_syncing})
               end
             end) do
        monitor = Process.monitor(pid)

        receive do
          {^ref, :started} ->
            Process.demonitor(monitor, [:flush])

            try do
              result = set_status(source, %{status: "syncing", error: nil})
              send(pid, {ref, result})
              result
            rescue
              error ->
                send(pid, {ref, :cancel})
                reraise error, __STACKTRACE__
            end

          {^ref, :already_syncing} ->
            Process.demonitor(monitor, [:flush])
            {:error, :already_syncing}

          {:DOWN, ^monitor, :process, ^pid, reason} ->
            {:error, reason}
        end
      end
    else
      {:ok, source}
    end
  end

  defp finish_sync(source, result, retries \\ 100) do
    # Older callers may still start a sync in a transaction. A quick git failure
    # must not leave that row stuck at "syncing" when it becomes visible later.
    case get(source.id) do
      nil when retries > 0 ->
        receive do
        after
          100 -> finish_sync(source, result, retries - 1)
        end

      nil ->
        :ok

      current ->
        attrs =
          case result do
            :ok -> %{status: "ready", error: nil, synced_at: DateTime.utc_now(:second)}
            {:error, reason} -> %{status: "error", error: reason}
          end

        # A concurrent deletion is harmless, including one after the lookup.
        Repo.update_all(from(s in Source, where: s.id == ^current.id),
          set: Map.to_list(Map.put(attrs, :updated_at, DateTime.utc_now(:second)))
        )

        Agents.notify_changed()
        forget_context(current.workflow_id)
    end
  end

  defp set_status(source, attrs) do
    result = source |> Source.status_changeset(attrs) |> Repo.update()
    Agents.notify_changed()
    result
  end

  defp git_sync(source) do
    dir = local_path(source)
    branch = Factory.Text.presence(source.config["branch"])

    deadline =
      System.monotonic_time(:millisecond) +
        Application.get_env(:factory, :source_sync_timeout, 300_000)

    with {:ok, env} <- git_env(source) do
      steps =
        if File.dir?(Path.join(dir, ".git")) do
          [
            ["-C", dir, "fetch", "--depth", "1", "--", "origin", branch || "HEAD"],
            ["-C", dir, "reset", "--hard", "FETCH_HEAD"]
          ]
        else
          File.mkdir_p!(Path.dirname(dir))
          File.rm_rf!(dir)

          [
            ["clone", "--depth", "1"] ++
              if(branch, do: ["--branch", branch], else: []) ++ ["--", remote_url(source), dir]
          ]
        end

      Enum.reduce_while(steps, :ok, fn args, :ok ->
        case Factory.GitCmd.run(nil, args,
               env: env,
               timeout: max(deadline - System.monotonic_time(:millisecond), 0),
               executable: Application.get_env(:factory, :sources_git_executable) || "git"
             ) do
          {:ok, _, 0} ->
            {:cont, :ok}

          {:ok, out, _} ->
            {:halt, {:error, git_error(out)}}

          {:error, :timeout} ->
            {:halt, {:error, "Syncing timed out and was stopped."}}

          {:error, reason} when is_binary(reason) ->
            {:halt, {:error, "Couldn't run git: #{reason}"}}

          {:error, reason} ->
            {:halt, {:error, "Couldn't run git: #{inspect(reason)}"}}
        end
      end)
    end
  rescue
    e in ErlangError -> {:error, "Couldn't run git: #{Exception.message(e)}"}
  end

  # Never prompts for a password (it would hang). An Azure DevOps token goes in as an
  # HTTP header through git's environment config, so it isn't on the command line
  # or saved to disk.
  # Besides what `Factory.GitCmd` sets for every git: a personal access token.
  defp git_env(%Source{kind: "azure_devops", config: c}) do
    case Factory.Text.presence(c["pat_env"]) do
      nil ->
        {:ok, []}

      var ->
        case System.get_env(var) do
          nil ->
            {:error,
             "The environment variable #{var} isn't set. Set it to your personal access token and restart Factory, then sync again."}

          pat ->
            header = "Authorization: Basic " <> Base.encode64(":" <> pat)

            {:ok,
             [
               {"GIT_CONFIG_COUNT", "1"},
               {"GIT_CONFIG_KEY_0", "http.extraHeader"},
               {"GIT_CONFIG_VALUE_0", header}
             ]}
        end
    end
  end

  defp git_env(_source), do: {:ok, []}

  defp git_error(out) do
    out = String.trim(out)

    cond do
      out =~ ~r/could not read Username|Authentication failed|terminal prompts disabled/i ->
        "Git couldn't sign in. For Azure DevOps, name an environment variable holding a personal access token, or sign in with git's credential manager once."

      out =~ ~r/not found|does not exist/i ->
        "The repository or branch wasn't found. Check the names."

      true ->
        out |> String.slice(-600, 600) |> without_credentials()
    end
  end

  # An address as an agent or the page may see it: without a user and password in it
  # (`https://me:ghp_…@host/repo`), which would otherwise go into prompts and errors.
  defp shown_url(url) do
    case URI.parse(url) do
      %URI{userinfo: info} = uri when is_binary(info) -> URI.to_string(%{uri | userinfo: nil})
      _ -> url
    end
  end

  defp without_credentials(text),
    do: Regex.replace(~r{(\w+://)[^/\s@]+@}, text, "\\1")

  # Context for Kiro

  # Bytes of an instruction file or meta index that go into a prompt.
  @max_text 30_000

  @doc "The enabled, ready sources attached to an agent, as text for its prompt."
  def context_for_agent(%{id: agent_id}) do
    Repo.all(
      from s in Source,
        join: l in Link,
        on: l.source_id == s.id,
        where: l.agent_id == ^agent_id,
        order_by: s.id
    )
    |> render_context()
  end

  @doc """
  All of a workflow's enabled, ready sources as text for Kiro, or "" when there are none.
  Folders and repositories are pointed to (Kiro reads what it needs); instruction
  files and meta indexes are included.
  """
  def context(nil), do: ""

  def context(workflow_id), do: workflow_id |> list() |> render_context()

  defp render_context(sources) do
    parts = for s <- sources, s.enabled, s.status == "ready", part = describe(s), do: part

    case parts do
      [] ->
        ""

      parts ->
        """
        <data-sources>
        Besides the project folder, work from these sources. Read what a task needs; don't change them.

        #{Enum.join(parts, "\n\n")}
        </data-sources>\
        """
    end
  end

  defp describe(%Source{kind: kind} = s) when kind in ["azure_devops", "git"] do
    if s.synced_at do
      where =
        if kind == "git",
          do: shown_url(remote_url(s)),
          else: "Azure DevOps #{s.config["org"]}/#{s.config["project"]}/#{s.config["repo"]}"

      branch = if b = Factory.Text.presence(s.config["branch"]), do: ", branch #{b}", else: ""

      "## Repository \"#{s.name}\" (#{where}#{branch})\nA local copy is at #{local_path(s)}."
    end
  end

  defp describe(%Source{kind: "folder"} = s),
    do: "## Folder \"#{s.name}\"\n#{local_path(s)}"

  defp describe(%Source{kind: "instructions"} = s) do
    "## Instructions \"#{s.name}\"\nFollow these in all your work:\n\n#{text(s)}"
  end

  # A tree's part of the prompt is kept until its file, the source or its section files
  # change, so a large tree isn't read and decoded again for every prompt. It lives in
  # :persistent_term, cheap to read and only costly to change, which a tree seldom does.
  defp describe(%Source{kind: "pageindex"} = s) do
    key = {__MODULE__, :pageindex, s.id}

    case :persistent_term.get(key, nil) do
      {stamp, text} ->
        if stamp == tree_stamp(s), do: text, else: describe_tree(s, key)

      nil ->
        describe_tree(s, key)
    end
  end

  defp describe(%Source{kind: "meta_index"} = s) do
    root =
      Factory.Text.presence(s.config["root"]) ||
        (s.config["path"] && Path.dirname(Path.expand(s.config["path"])))

    at = if s.config["path"], do: " at #{Path.expand(s.config["path"])}", else: ""
    rel = if root, do: " Paths in it are relative to #{Path.expand(root)}.", else: ""

    """
    ## Meta index "#{s.name}"
    This index#{at} maps where things are.#{rel} Read it first, then open only what the task needs.

    <index>
    #{text(s)}
    </index>\
    """
  end

  # Taken after the text is made, since making it may write the section files.
  defp describe_tree(s, key) do
    text = render_tree(s)
    :persistent_term.put(key, {tree_stamp(s), text})
    text
  end

  # What the text depends on: the source, and the tree file and section files as they
  # are on disk.
  defp tree_stamp(s) do
    stat = fn path ->
      case File.stat(path, time: :posix) do
        {:ok, st} -> {st.mtime, st.size, st.inode}
        {:error, _} -> nil
      end
    end

    dir = sections_dir(s)
    {s.name, s.config, dir, stat.(Path.expand(s.config["path"] || "")), stat.(dir)}
  end

  defp render_tree(%Source{} = s) do
    case PageIndex.load(s.config["path"]) do
      {:ok, tree} ->
        dir = if tree.text?, do: ensure_sections(s, tree)
        doc = Factory.Text.presence(s.config["document"])

        how =
          cond do
            dir ->
              "Each section's text is in its own file (shown after →); open only the ones the task needs."

            doc ->
              "Read only the pages the task needs from the document at #{Path.expand(doc)}."

            true ->
              "Use it to find where things are; ask for a section's text if you need it."
          end

        """
        ## PageIndex "#{s.name}"
        A table of contents of "#{tree.doc_name}" (#{tree.count} sections), with pages and summaries. #{how}

        <pageindex>
        #{PageIndex.outline(tree.nodes, dir)}
        </pageindex>\
        """

      {:error, why} ->
        "## PageIndex \"#{s.name}\"\n(The tree at #{s.config["path"]} #{why}.)"
    end
  end

  # A tree's sections as files, written again when the tree file changes.
  defp ensure_sections(source, tree) do
    dir = sections_dir(source)

    stale =
      case {File.stat(Path.expand(source.config["path"]), time: :posix),
            File.stat(dir, time: :posix)} do
        {{:ok, tree_stat}, {:ok, dir_stat}} -> tree_stat.mtime > dir_stat.mtime
        _ -> true
      end

    if stale, do: PageIndex.write_sections(tree.nodes, dir)
    dir
  end

  defp sections_dir(%Source{} = s), do: Path.join(own_dir(s), "sections")

  # A file's text, read now so edits to it count; else the text given. Over the limit
  # it's cut with a line saying how much was left out, like the rest of a prompt.
  defp text(%Source{config: %{"path" => path}} = s) when is_binary(path) and path != "" do
    case File.read(Path.expand(path)) do
      {:ok, body} -> bounded(body)
      {:error, _} -> "(#{s.name} couldn't be read at #{path}.)"
    end
  end

  defp text(%Source{content: content}), do: bounded(content || "")

  defp bounded(text) do
    {text, _omitted} = text |> String.trim() |> Factory.Context.Bounds.excerpt(@max_text)
    text
  end
end
