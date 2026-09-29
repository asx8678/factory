defmodule Factory.SourcesTest do
  # Not async: syncing runs git in a background task that needs the shared sandbox.
  use Factory.DataCase, async: false
  alias Factory.{Agents, Chat, Kiro, Runs, Sources, Specs, Workflows}

  setup do
    {:ok, workflow} = Workflows.create("Docs flow")

    tmp =
      Path.join(
        System.tmp_dir!(),
        "factory-sources-#{System.get_env("MIX_TEST_PARTITION")}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    previous = Application.get_env(:factory, :sources_dir)
    Application.put_env(:factory, :sources_dir, Path.join(tmp, "sources"))

    on_exit(fn ->
      Application.put_env(:factory, :sources_dir, previous)
      File.rm_rf(tmp)
    end)

    %{workflow: workflow, tmp: tmp}
  end

  test "each kind checks what it needs", %{workflow: w, tmp: tmp} do
    assert {:error, cs} =
             Sources.create(w.id, %{
               kind: "folder",
               name: "Docs",
               config: %{"path" => "/no/such/dir"}
             })

    assert [{:config, {"isn't a folder on this machine", [field: "path"]}}] = cs.errors

    assert {:error, _} = Sources.create(w.id, %{kind: "instructions", name: "Rules"})

    assert {:error, _} =
             Sources.create(w.id, %{
               kind: "azure_devops",
               name: "Repo",
               config: %{"org" => "contoso"}
             })

    assert {:error, _} =
             Sources.create(w.id, %{kind: "git", name: "Repo", config: %{"url" => "ftp://x"}})

    assert {:ok, _} =
             Sources.create(w.id, %{kind: "folder", name: "Docs", config: %{"path" => tmp}})
  end

  test "agents and Kiro get the enabled sources as context", %{workflow: w, tmp: tmp} do
    index = Path.join(tmp, "00-index.md")
    File.write!(index, "- 01-architecture.md: modules")

    {:ok, _} =
      Sources.create(w.id, %{kind: "folder", name: "Design docs", config: %{"path" => tmp}})

    {:ok, rules} =
      Sources.create(w.id, %{kind: "instructions", name: "Rules", content: "Always write tests."})

    {:ok, _} =
      Sources.create(w.id, %{kind: "meta_index", name: "Spec index", config: %{"path" => index}})

    text = Sources.context(w.id)
    assert text =~ "## Folder \"Design docs\"\n#{tmp}"
    assert text =~ "Always write tests."
    assert text =~ "- 01-architecture.md: modules"
    assert text =~ "Paths in it are relative to #{tmp}"

    # The index file is read fresh each time.
    File.write!(index, "- 02-data.md: tables")
    assert Sources.context(w.id) =~ "02-data.md"

    {:ok, _} = Sources.toggle(rules)
    refute Sources.context(w.id) =~ "Always write tests."
    assert Sources.context(Workflows.create("Empty") |> elem(1) |> Map.fetch!(:id)) == ""

    # A cloned workflow gets copies of the sources, attached to the copied agents.
    {:ok, agent} = Agents.create_agent(%{name: "Reader", workflow_id: w.id})
    [folder | _] = Sources.list(w.id)
    {:ok, _} = Sources.attach(folder, agent.id)
    {:ok, copy} = Workflows.clone(w)
    assert length(Sources.list(copy.id)) == 3
    [copied_agent] = Agents.list_agents(copy.id)
    assert [{_, id}] = Sources.links(copy.id)
    assert id == copied_agent.id

    # A source can't be attached to another workflow's agent.
    assert {:error, :other_workflow} = Sources.attach(folder, copied_agent.id)
  end

  test "a long instruction file is cut with a line saying how much was left out", %{
    workflow: w
  } do
    body = String.duplicate("Use British spelling. ", 2000)

    {:ok, _} =
      Sources.create(w.id, %{kind: "instructions", name: "Rules", content: body})

    text = Sources.context(w.id)
    assert text =~ ~r/\[omitted \d+ UTF-8 bytes\]/
    assert byte_size(text) < byte_size(body)
  end

  test "an agent's first message carries the sources attached to it, and only those",
       %{workflow: w} do
    {:ok, rules} =
      Sources.create(w.id, %{
        kind: "instructions",
        name: "Rules",
        content: "Use British spelling."
      })

    {:ok, _} =
      Sources.create(w.id, %{kind: "instructions", name: "Other", content: "Not for you."})

    {:ok, agent} = Agents.create_agent(%{name: "Writer", runtime: "kiro_v3", workflow_id: w.id})
    on_exit(fn -> Kiro.stop(agent.id) end)
    {:ok, _} = Sources.attach(rules, agent.id)
    assert Sources.agent_ids(rules) == [agent.id]

    {:ok, run} = Runs.create_run()
    {:ok, run} = Runs.update_run(run, %{settings: %{"workflow_id" => w.id}})
    Runs.subscribe(run.id)
    Chat.handle(run, "/ask Writer hello")

    assert_receive {:message, %{author: "Writer", body: body}}, 5_000
    assert body =~ "<data-sources>"
    assert body =~ "Use British spelling."
    refute body =~ "Not for you."
    assert body =~ "hello"

    # Detached, it's gone from the prompt (sent again with the next message).
    {:ok, _} = Sources.detach(rules, agent.id)
    assert Sources.context_for_agent(agent) == ""
  end

  test "a git repository is cloned, pulled again and removed with its source", %{
    workflow: w,
    tmp: tmp
  } do
    remote = Path.join(tmp, "remote")
    work = Path.join(tmp, "work")
    git = fn args, dir -> {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true) end
    File.mkdir_p!(work)
    git.(["init", "-q", "-b", "main"], work)
    File.write!(Path.join(work, "README.md"), "first")
    git.(["-c", "user.email=t@t", "-c", "user.name=t", "add", "."], work)
    git.(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "one"], work)
    git.(["clone", "-q", "--bare", work, remote], tmp)

    {:ok, source} =
      Sources.create(w.id, %{kind: "git", name: "API", config: %{"url" => "file://#{remote}"}})

    source = await_sync(source)
    assert source.status == "ready"
    assert File.read!(Path.join(Sources.local_path(source), "README.md")) == "first"
    assert Sources.context(w.id) =~ "## Repository \"API\" (file://#{remote})"

    # A new commit arrives with the next sync.
    File.write!(Path.join(work, "README.md"), "second")
    git.(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qam", "two"], work)
    git.(["push", "-q", remote, "main"], work)
    {:ok, _} = Sources.sync(source)
    source = await_sync(source)
    assert File.read!(Path.join(Sources.local_path(source), "README.md")) == "second"

    path = Sources.local_path(source)
    {:ok, _} = Sources.delete(source)
    refute File.exists?(path)
  end

  test "an Azure DevOps token comes from the named environment variable", %{workflow: w} do
    {:ok, source} =
      Sources.create(w.id, %{
        kind: "azure_devops",
        name: "Backend",
        config: %{
          "org" => "contoso",
          "project" => "My Shop",
          "repo" => "api",
          "pat_env" => "FACTORY_TEST_UNSET_PAT"
        }
      })

    assert Sources.remote_url(source) == "https://dev.azure.com/contoso/My%20Shop/_git/api"
    source = await_sync(source)
    assert source.status == "error"
    assert source.error =~ "FACTORY_TEST_UNSET_PAT isn't set"
  end

  test "Kiro's prompts for a run's spec include its workflow's sources", %{workflow: w} do
    {:ok, _} =
      Sources.create(w.id, %{kind: "instructions", name: "Rules", content: "Keep it small."})

    {:ok, spec} = Specs.create_spec("S", %{overview: "# O"})
    {:ok, run} = Runs.create_run("R")

    {:ok, _} =
      Runs.update_run(run, %{kind: "bug", spec_id: spec.id, settings: %{"workflow_id" => w.id}})

    assert {"data-sources.md", text} = List.last(Specs.kiro_files(spec))
    assert text =~ "Keep it small."
    refute Enum.any?(Specs.files(spec), &(elem(&1, 0) == "data-sources.md"))
  end

  test "repository creation and copying can defer syncing until after commit", %{workflow: w} do
    attrs = %{
      kind: "azure_devops",
      name: "Deferred",
      config: %{
        "org" => "o",
        "project" => "p",
        "repo" => "r",
        "pat_env" => "FACTORY_TEST_UNSET_PAT"
      }
    }

    assert {:ok, source} = Repo.transact(fn -> Sources.create(w.id, attrs, sync: false) end)
    assert :global.whereis_name({Sources, source.id}) == :undefined
    assert source.status == "ready"
    assert source.synced_at == nil

    {:ok, copied_workflow} = Workflows.create("Deferred copy")

    assert {:ok, :ok} =
             Repo.transact(fn ->
               {:ok, Sources.copy(w.id, copied_workflow.id, %{}, sync: false)}
             end)

    [copy] = Sources.list(copied_workflow.id)
    assert :global.whereis_name({Sources, copy.id}) == :undefined
    assert copy.synced_at == nil

    assert {:ok, %{status: "syncing"}} = Sources.start_sync(source)
    assert %{status: "error", error: error} = await_sync(source)
    assert error =~ "FACTORY_TEST_UNSET_PAT isn't set"
  end

  test "a timed out sync kills git and its child and refuses overlapping syncs", %{
    workflow: w,
    tmp: tmp
  } do
    executable = Path.join(tmp, "git")
    pids_path = Path.join(tmp, "git-pids")
    # The shell acts like git waiting on an SSH helper. Neither exits on port EOF.
    File.write!(executable, """
    #!/bin/sh
    sleep 30 &
    printf '%s %s' "$$" "$!" > '#{pids_path}'
    wait
    """)

    File.chmod!(executable, 0o755)
    previous = Application.get_env(:factory, :sources_git_executable)
    previous_timeout = Application.get_env(:factory, :source_sync_timeout)
    Application.put_env(:factory, :sources_git_executable, executable)
    Application.put_env(:factory, :source_sync_timeout, 1_000)

    on_exit(fn ->
      restore_env(:sources_git_executable, previous)
      restore_env(:source_sync_timeout, previous_timeout)
    end)

    {:ok, source} =
      Sources.create(w.id, %{kind: "git", name: "Slow", config: %{"url" => "file:///unused"}},
        sync: false
      )

    assert {:ok, _} = Sources.start_sync(source)
    assert {:error, :already_syncing} = Sources.start_sync(source)
    assert %{status: "error", error: "Syncing timed out and was stopped."} = await_sync(source)

    for pid <- pids_path |> File.read!() |> String.split() do
      assert {_output, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
      assert status != 0
    end

    assert :global.whereis_name({Sources, source.id}) == :undefined

    Application.put_env(:factory, :sources_git_executable, System.find_executable("true"))
    assert {:ok, _} = Sources.start_sync(source)
    assert %{status: "ready"} = await_sync(source)
  end

  test "completion retries when the source row is not visible yet", %{workflow: w} do
    {:ok, source} =
      Sources.create(
        w.id,
        %{
          kind: "azure_devops",
          name: "Delayed row",
          config: %{
            "org" => "o",
            "project" => "p",
            "repo" => "r",
            "pat_env" => "FACTORY_TEST_UNSET_PAT"
          }
        },
        sync: false
      )

    # Hide the row after setting its status, then pause the failed final lookup.
    # This models an uncommitted insert without concurrent sandbox transactions.
    parent = self()
    ref = make_ref()

    :telemetry.attach(
      ref,
      [:factory, :repo, :query],
      &__MODULE__.pause_completion/4,
      {parent, ref, source}
    )

    on_exit(fn -> :telemetry.detach(ref) end)
    assert {:ok, _} = Sources.start_sync(source)
    assert_receive {^ref, worker}, 1_000
    :telemetry.detach(ref)
    assert Sources.get(source.id) == nil
    Repo.insert!(Ecto.put_meta(source, state: :built))
    send(worker, ref)
    assert %{status: "error", error: error} = await_sync(source)
    assert error =~ "FACTORY_TEST_UNSET_PAT isn't set"
  end

  def pause_completion(_event, _measurements, metadata, {parent, ref, source}) do
    if metadata[:source] == "data_sources" do
      cond do
        self() == parent and String.starts_with?(metadata.query, "UPDATE") ->
          Repo.delete!(source)

        self() != parent and String.starts_with?(metadata.query, "SELECT") ->
          send(parent, {ref, self()})

          receive do
            ^ref -> :ok
          after
            1_000 -> :ok
          end

        true ->
          :ok
      end
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:factory, key)
  defp restore_env(key, value), do: Application.put_env(:factory, key, value)

  defp await_sync(source) do
    case :global.whereis_name({Sources, source.id}) do
      :undefined ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000
        assert reason in [:normal, :noproc]
    end

    Sources.get(source.id)
  end
end
