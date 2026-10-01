defmodule FactoryWeb.MCPTest do
  use FactoryWeb.ConnCase, async: true
  alias Factory.{Agents, PlanTools, Repo, Runs, Specs}

  setup do
    {:ok, planner} = Agents.create_agent(%{name: "Planner", kind: "planner"})
    {:ok, run} = Runs.create_run()
    generation = Ecto.UUID.generate()
    run = run |> Ecto.Changeset.change(planner_generation: generation) |> Repo.update!()
    %{run: run, token: PlanTools.grant(run.id, generation, planner)}
  end

  defp rpc(conn, method, params, token \\ nil) do
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", JSON.encode!(%{jsonrpc: "2.0", id: 7, method: method, params: params}))
  end

  defp call_tool(conn, token, name, args) do
    %{"id" => 7, "result" => %{"content" => [%{"text" => text}], "isError" => error?}} =
      conn |> rpc("tools/call", %{name: name, arguments: args}, token) |> json_response(200)

    {text, error?}
  end

  test "initialize answers with the client's protocol version and the tools capability", %{
    conn: conn
  } do
    result = conn |> rpc("initialize", %{protocolVersion: "2025-11-25"}) |> json_response(200)

    assert %{"protocolVersion" => "2025-11-25", "capabilities" => %{"tools" => %{}}} =
             result["result"]
  end

  test "a run step's token gets the run tools, which mark its tasks done", %{conn: conn} do
    {:ok, run} = Runs.create_run()

    {:ok, run} =
      Runs.attach_spec(run, [{"tasks.md", "- [ ] 1. Ship it"}], [%{ref: "1", title: "Ship it"}])

    {:ok, run} = Runs.update_run(run, %{status: "running", progress: %{"current" => "agent-1"}})
    token = Factory.RunTools.grant(run.id, "agent-1")

    %{"result" => %{"tools" => tools}} =
      conn |> rpc("tools/list", %{}, token) |> json_response(200)

    assert Enum.map(tools, & &1["name"]) == ["get_tasks", "complete_tasks"]

    assert {"Marked done. Tasks (1 of 1 done):\n1. [x] Ship it", false} =
             call_tool(conn, token, "complete_tasks", %{numbers: ["1"]})

    # A planner's tool isn't one of a run step's.
    assert {"There's no tool add_tasks.", true} = call_tool(conn, token, "add_tasks", %{})
  end

  test "a session's token is only good with its running session; a step's expires after a day" do
    sign = fn data, days ->
      Phoenix.Token.sign(FactoryWeb.Endpoint, "factory run tools", data,
        signed_at: System.system_time(:second) - days * 86_400
      )
    end

    # No session with this key runs, so no nonce matches: an old-style token without a
    # nonce, one with a made-up nonce, and one minted for it now are all refused.
    refute Factory.RunTools.token?(sign.(%{session: 1}, 3))
    refute Factory.RunTools.token?(sign.(%{session: 1, nonce: "made-up"}, 0))
    refute Factory.RunTools.token?(Factory.RunTools.grant_session(1))
    assert Factory.RunTools.tools(Factory.RunTools.grant_session(1)) == []

    assert {"Factory didn't recognise" <> _, true} =
             call_tool(build_conn(), Factory.RunTools.grant_session(1), "get_tasks", %{})

    # A session's token is also a week old at most.
    refute Factory.RunTools.token?(sign.(%{session: 1, nonce: "n"}, 8))

    refute Factory.RunTools.token?(
             sign.(%{run_id: 1, step_id: "agent-1", tasks: true, verdict: false}, 3)
           )

    assert Factory.RunTools.token?(
             sign.(%{run_id: 1, step_id: "agent-1", tasks: true, verdict: false}, 0)
           )
  end

  test "tools/list gives the plan tools without a token", %{conn: conn} do
    %{"result" => %{"tools" => tools}} = conn |> rpc("tools/list", %{}) |> json_response(200)

    assert Enum.map(tools, & &1["name"]) ==
             ~w(get_plan create_plan update_plan add_tasks update_task remove_tasks ask_user)
  end

  test "notifications are accepted without a reply; GET and unknown methods are refused", %{
    conn: conn
  } do
    note =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", JSON.encode!(%{jsonrpc: "2.0", method: "notifications/initialized"}))

    assert note.status == 202
    assert build_conn() |> get("/mcp") |> response(405)

    assert %{"error" => %{"code" => -32601}} =
             build_conn() |> rpc("server/discover", %{}) |> json_response(200)
  end

  test "a call without a good token is a tool error, not an HTTP one", %{conn: conn} do
    assert {"Factory didn't recognise" <> _, true} =
             call_tool(conn, "forged", "get_plan", %{})
  end

  test "the planner creates a plan, then adds, inserts, changes and removes tasks", %{
    conn: conn,
    run: run,
    token: token
  } do
    assert {"Plan created." <> _, false} =
             call_tool(conn, token, "create_plan", %{
               summary: "Export invoices as CSV.",
               approach: "A button and a CSV module."
             })

    {text, false} =
      call_tool(build_conn(), token, "add_tasks", %{
        tasks: [
          %{title: "Add the button", details: ["In `invoices_live.ex`."]},
          %{title: "Write the CSV", requirements: ["1.1"]}
        ]
      })

    assert text =~ "1. Add the button\n2. Write the CSV"

    {text, false} =
      call_tool(build_conn(), token, "add_tasks", %{tasks: [%{title: "Read the page"}], after: 0})

    assert text =~ "1. Read the page\n2. Add the button\n3. Write the CSV"

    {_, false} =
      call_tool(build_conn(), token, "update_task", %{number: 3, title: "Stream the CSV"})

    {_, false} = call_tool(build_conn(), token, "remove_tasks", %{numbers: [1]})

    spec = Specs.get_spec(Runs.get_run(run.id).spec_id)
    assert spec.design =~ "# Approach\n\nExport invoices as CSV."
    # A changed task keeps what it had and is numbered again.
    assert spec.tasks =~ "- [ ] 2. Stream the CSV\n  - _Requirements: 1.1_"

    assert Enum.map(Runs.get_run(run.id).tasks, & &1.title) == [
             "Add the button",
             "Stream the CSV"
           ]

    assert {"There's no task 9." <> _, true} =
             call_tool(build_conn(), token, "update_task", %{number: 9, title: "Nope"})
  end

  test "a design the person wrote isn't replaced by the planner's approach", %{
    conn: conn,
    run: run,
    token: token
  } do
    {:ok, _} = Specs.update_spec(Specs.for_run(run), %{design: "# Design\n\nMine."})

    {_, false} = call_tool(conn, token, "create_plan", %{summary: "S", approach: "A"})

    assert Specs.get_spec(Runs.get_run(run.id).spec_id).design == "# Design\n\nMine."
  end

  test "tasks added to a plain numbered tasks file are read back as tasks", %{
    conn: conn,
    run: run,
    token: token
  } do
    {:ok, _} = Specs.update_spec(Specs.for_run(run), %{tasks: "1. First\n2. Second\n"})

    {text, false} = call_tool(conn, token, "add_tasks", %{tasks: [%{title: "Third"}]})

    assert text =~ "1. First\n2. Second\n3. Third"
    assert length(Runs.get_run(run.id).tasks) == 3
  end

  test "a started run's plan can't be changed", %{conn: conn, run: run, token: token} do
    {:ok, _} = Runs.update_run(run, %{status: "queued"})

    assert {"This plan was replaced" <> _, true} =
             call_tool(conn, token, "add_tasks", %{tasks: [%{title: "Late"}]})
  end
end
