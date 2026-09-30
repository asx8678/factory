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

  describe "env_allowed?/1" do
    test "plain upper-case names, never Factory's own secrets" do
      assert Actions.env_allowed?("GITHUB_TOKEN")
      assert Actions.env_allowed?(" SLACK_WEBHOOK_URL ")
      assert Actions.env_allowed?("A1_B2")

      refute Actions.env_allowed?("SECRET_KEY_BASE")
      refute Actions.env_allowed?("DATABASE_URL")
      refute Actions.env_allowed?("MY_SECRET")
      refute Actions.env_allowed?("SSH_PRIVATE_KEY")
      refute Actions.env_allowed?("DB_PASSWORD")
      refute Actions.env_allowed?("github_token")
      refute Actions.env_allowed?("1TOKEN")
      refute Actions.env_allowed?("TOKEN=x")
      refute Actions.env_allowed?("$HOME")
      refute Actions.env_allowed?("")
      refute Actions.env_allowed?(nil)
    end

    test "only the configured names when there's a list" do
      Application.put_env(:factory, :action_env_vars, ["GITHUB_TOKEN"])
      on_exit(fn -> Application.delete_env(:factory, :action_env_vars) end)

      assert Actions.env_allowed?("GITHUB_TOKEN")
      refute Actions.env_allowed?("OTHER_TOKEN")
      refute Actions.env_allowed?("SECRET_KEY_BASE")
    end
  end

  describe "safe_url?/1" do
    test "public http(s) addresses" do
      assert Actions.safe_url?("https://api.example.com/deploys")
      assert Actions.safe_url?("http://hooks.slack.com/x")
      assert Actions.safe_url?("https://api.example.com/deploys/{{run_id}}")
      assert Actions.safe_url?("https://8.8.8.8/")
      assert Actions.safe_url?("https://[2001:db8::1]/")
      assert Actions.safe_url?("https://example.test/step")
    end

    test "nothing on this machine or a private network, and nothing but http(s)" do
      for url <- [
            "http://localhost:4000/",
            "http://LOCALHOST/",
            "http://localhost./",
            "http://127.0.0.1/",
            "http://127.1.2.3/",
            "http://0.0.0.0/",
            "http://10.0.0.5/",
            "http://172.16.0.1/",
            "http://172.31.255.255/",
            "http://192.168.1.1/",
            "http://169.254.169.254/latest/meta-data",
            "http://[::1]/",
            "http://[::]/",
            "http://[fc00::1]/",
            "http://[fd12::1]/",
            "http://[fe80::1]/",
            "http://[::ffff:127.0.0.1]/",
            "http://[::ffff:10.0.0.1]/",
            "http://db.internal/",
            "http://printer.local/",
            "http://x.localhost/",
            "ftp://example.com/",
            "file:///etc/passwd",
            "example.com/no-scheme",
            "https://",
            ""
          ] do
        refute Actions.safe_url?(url), url
      end

      refute Actions.safe_url?(nil)
      assert Actions.safe_url?("http://172.15.0.1/")
      assert Actions.safe_url?("http://172.32.0.1/")
    end

    test "private addresses when Factory is told to allow them" do
      Application.put_env(:factory, :allow_private_action_urls, true)
      on_exit(fn -> Application.delete_env(:factory, :allow_private_action_urls) end)

      assert Actions.safe_url?("http://localhost:4000/hook")
      assert Actions.safe_url?("http://10.0.0.5/")
      refute Actions.safe_url?("ftp://10.0.0.5/")
    end
  end

  test "settings that aren't what they should be stop the action", %{workflow: w} do
    card = action(w, "github_issue", %{"repo" => "acme/api/../x", "issue" => "42 or 1"})

    assert Actions.invalid(card) == [
             "Repository must be owner/name, not acme/api/../x.",
             "Issue number must be a number, not 42 or 1."
           ]

    assert {:error, "Repository must be owner/name" <> _} = Actions.plan(card)

    card = action(w, "github_issue", %{"repo" => "acme/api", "issue" => "42", "close" => "yes"})
    assert Actions.invalid(card) == []
    {:ok, [comment, close]} = Actions.plan(card)
    assert comment =~ "POST https://api.github.com/repos/acme/api/issues/42/comments"
    assert close =~ "PATCH https://api.github.com/repos/acme/api/issues/42"

    card = action(w, "github_pr", %{"repo" => "acme/api", "token_env" => "SECRET_KEY_BASE"})

    assert Actions.invalid(card) == [
             "Token variable: SECRET_KEY_BASE isn't an environment variable an action may read."
           ]

    assert {:error, "Token variable: SECRET_KEY_BASE isn't" <> _} = Actions.plan(card)

    card = action(w, "api_request", %{"url" => "http://127.0.0.1:4000/admin"})
    assert [_] = Actions.invalid(card)
    assert {:error, "URL: http://127.0.0.1:4000/admin must be a public" <> _} = Actions.run(card)

    # A private address that only shows once the template is filled in is caught as well.
    card = action(w, "api_request", %{"url" => "http://{{summary}}/x"})
    assert Actions.invalid(card) == []
    ctx = Map.put(Actions.context(), "summary", "169.254.169.254")
    assert {:error, "http://169.254.169.254/x isn't a public" <> _} = Actions.run(card, ctx)

    card = action(w, "webhook", %{"url_env" => "DATABASE_URL"})

    assert {:error, "Webhook URL variable: DATABASE_URL isn't an environment variable" <> _} =
             Actions.run(card)
  end

  test "a webhook address from the environment must be public too", %{workflow: w} do
    System.put_env("FACTORY_TEST_HOOK", "http://localhost:9/hook")
    on_exit(fn -> System.delete_env("FACTORY_TEST_HOOK") end)

    card = action(w, "webhook", %{"url_env" => "FACTORY_TEST_HOOK"})
    assert {:ok, [line]} = Actions.plan(card)
    assert line =~ "$FACTORY_TEST_HOOK"
    assert {:error, "http://localhost:9/hook isn't a public" <> _} = Actions.run(card)
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
