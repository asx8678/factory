defmodule Factory.ActionsTest do
  use Factory.DataCase, async: false
  import Swoosh.TestAssertions
  alias Factory.{Actions, Agents, Sources, Workflows}

  setup do
    {:ok, w} = Workflows.create("Ship it")
    %{workflow: w}
  end

  defp action(w, type, config) do
    {:ok, card} = Agents.add_action(w.id, type, 300.0, 0.0)

    {:ok, card} =
      Agents.update_agent(card, %{
        action: %{"type" => type, "config" => Map.merge(card.action["config"], config)}
      })

    card
  end

  test "a new action has its type's defaults and says what's still missing", %{workflow: w} do
    {:ok, card} = Agents.add_action(w.id, "github_pr", 0.0, 0.0)
    assert card.kind == "action" and card.name == "Create GitHub PR"
    assert card.action["config"]["title"] == "{{run}}"
    assert card.action["config"]["token_env"] == "GITHUB_TOKEN"
    assert Actions.missing(card) == ["Repository"]

    # Actions aren't agents: data sources can't be attached to them.
    {:ok, src} = Sources.create(w.id, %{kind: "instructions", name: "R", content: "x"})
    assert {:error, :action} = Sources.attach(src, card.id)
  end

  test "a dry run says what it would do, with templates filled in", %{workflow: w} do
    card = action(w, "github_pr", %{"repo" => "acme/api"})
    {:ok, [line]} = Actions.plan(card, Actions.context())

    assert line ==
             "Open a pull request on acme/api: factory/test → main, “Factory test run” (POST https://api.github.com/repos/acme/api/pulls)"

    card =
      action(w, "azure_item_close", %{"org" => "contoso", "project" => "My Shop", "item" => "42"})

    {:ok, [line]} = Actions.plan(card)
    assert line =~ "Work item 42 in contoso/My Shop: set state to Closed and add a comment"
    assert line =~ "PATCH https://dev.azure.com/contoso/My%20Shop/_apis/wit/workitems/42"
  end

  test "an API request sends its method, headers and JSON body", %{workflow: w} do
    System.put_env("FACTORY_TEST_API_TOKEN", "t0k")
    on_exit(fn -> System.delete_env("FACTORY_TEST_API_TOKEN") end)

    card =
      action(w, "api_request", %{
        "method" => "PUT",
        "url" => "https://api.example.com/deploys/{{run_id}}",
        "headers" => "X-Team: platform",
        "body" => ~s({"run": "{{run}}"}),
        "token_env" => "FACTORY_TEST_API_TOKEN"
      })

    Req.Test.stub(Factory.Actions, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert conn.method == "PUT"
      assert conn.request_path == "/deploys/test"
      assert Plug.Conn.get_req_header(conn, "x-team") == ["platform"]
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer t0k"]
      assert JSON.decode!(body) == %{"run" => "Factory test run"}
      Req.Test.json(conn, %{"ok" => true})
    end)

    assert {:ok, text} = Actions.run(card)
    assert text =~ "PUT https://api.example.com/deploys/test: HTTP 200"
    assert text =~ ~s("ok":true)
  end

  test "a summary with quotes and braces stays text inside a JSON body", %{workflow: w} do
    card =
      action(w, "api_request", %{
        "method" => "POST",
        "url" => "https://api.example.com/notes",
        "body" => ~s({"summary": "{{summary}}", "tags": ["{{run}}"]})
      })

    summary = ~s(He said "done", then {"admin": true})

    Req.Test.stub(Factory.Actions, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      assert JSON.decode!(body) == %{"summary" => summary, "tags" => ["Factory test run"]}
      Req.Test.json(conn, %{})
    end)

    assert {:ok, _} = Actions.run(card, Map.put(Actions.context(), "summary", summary))
  end

  test "tokens come from the environment; a missing one stops the action", %{workflow: w} do
    card =
      action(w, "azure_item_update", %{
        "org" => "c",
        "project" => "p",
        "item" => "7",
        "state" => "Active",
        "pat_env" => "FACTORY_TEST_UNSET"
      })

    assert {:error, "The environment variable FACTORY_TEST_UNSET isn't set." <> _} =
             Actions.run(card)
  end

  test "Azure DevOps work items are patched with state and comment", %{workflow: w} do
    System.put_env("FACTORY_TEST_PAT", "secret")
    on_exit(fn -> System.delete_env("FACTORY_TEST_PAT") end)

    card =
      action(w, "azure_item_close", %{
        "org" => "contoso",
        "project" => "shop",
        "item" => "42",
        "pat_env" => "FACTORY_TEST_PAT"
      })

    Req.Test.stub(Factory.Actions, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert conn.method == "PATCH"
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json-patch+json"]

      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Basic " <> Base.encode64(":secret")
             ]

      assert [
               %{"path" => "/fields/System.State", "value" => "Closed"},
               %{"path" => "/fields/System.History"}
             ] =
               JSON.decode!(body)

      Req.Test.json(conn, %{"id" => 42})
    end)

    assert {:ok, "Work item 42 in contoso/shop: set state to Closed and add a comment"} =
             Actions.run(card)
  end

  test "an email is sent through the mailer", %{workflow: w} do
    card = action(w, "email", %{"to" => "team@example.com", "body" => "All done: {{run}}"})
    assert {:ok, _} = Actions.run(card)

    assert_email_sent(
      subject: "Factory: Factory test run",
      text_body: "All done: Factory test run"
    )
  end

  test "a command must succeed; commit & push pushes the branch", %{workflow: w} do
    tmp = Path.join(System.tmp_dir!(), "factory-actions-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    ok = action(w, "command", %{"command" => "echo fine", "folder" => tmp})
    assert {:ok, text} = Actions.run(ok)
    assert text =~ "fine"
    bad = action(w, "command", %{"command" => "exit 3", "folder" => tmp})
    assert {:error, "`exit 3` failed (exit 3)" <> _} = Actions.run(bad)

    # Placeholder values reach the shell as data, never as code.
    echo = action(w, "command", %{"command" => ~s(printf '[%s]' "{{summary}}"), "folder" => tmp})
    ctx = %{Actions.context() | "summary" => "$(echo PWNED) `id` ; touch hacked"}
    assert {:ok, text} = Actions.run(echo, ctx)
    assert text =~ "[$(echo PWNED) `id` ; touch hacked]"
    refute File.exists?(Path.join(tmp, "hacked"))
    assert {:ok, [line]} = Actions.plan(echo, ctx)
    assert line =~ "$(echo PWNED)"

    remote = Path.join(tmp, "remote.git")
    work = Path.join(tmp, "work")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", remote])
    {_, 0} = System.cmd("git", ["clone", "-q", remote, work], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@t"], cd: work)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: work)
    File.write!(Path.join(work, "a.txt"), "change")

    push = action(w, "git_push", %{"folder" => work, "branch" => "factory/{{run_id}}"})
    assert {:ok, _} = Actions.run(push)
    {log, 0} = System.cmd("git", ["log", "--oneline", "factory/test"], cd: remote)
    assert log =~ "Factory test run"
  end
end
