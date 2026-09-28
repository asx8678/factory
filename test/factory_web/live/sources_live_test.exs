defmodule FactoryWeb.SourcesLiveTest do
  use FactoryWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Factory.{Sources, Workflows}

  test "the data sources window adds, edits, turns off and removes sources", %{conn: conn} do
    {:ok, w} = Workflows.create("Docs flow")
    {:ok, view, _html} = live(conn, ~p"/workflows/#{w.id}")

    # "Add data source" on the card under the toolbar opens the kinds to add.
    render_hook(view, "sources_open", %{"add" => "true"})

    assert has_element?(
             view,
             "#source-kinds #pick-source-azure_devops",
             "Azure DevOps repository"
           )

    assert has_element?(view, "#pick-source-meta_index", "Meta index")

    view |> element("#pick-source-folder") |> render_click()

    view
    |> form("#source-form", source: %{name: "Docs", config: %{path: "/no/such/dir"}})
    |> render_submit()

    assert has_element?(view, "#source-form", "isn't a folder on this machine")

    # Adding doesn't offer agents to tick: a new source starts attached to none.
    {:ok, _} = Factory.Agents.create_agent(%{name: "Early", workflow_id: w.id})
    refute has_element?(view, "#source-agents")
    assert has_element?(view, "#source-unattached-note")

    view
    |> form("#source-form", source: %{name: "Docs", config: %{path: File.cwd!()}})
    |> render_submit()

    [new] = Sources.list(w.id)
    assert Sources.agent_ids(new) == []

    # Adding closes the window; the card on the canvas shows the new source.
    refute has_element?(view, "#sources-window")
    render_hook(view, "sources_open", %{})
    [source] = Sources.list(w.id)
    assert has_element?(view, "#source-#{source.id}", "Docs")
    # The card on the canvas lists it.
    assert_push_event(view, "flow:graph", %{sources: [%{name: "Docs", label: "Local folder"}]})

    # Instruction text can be uploaded; it fills the box and names the source.
    view |> element("#add-source") |> render_click()
    view |> element("#pick-source-instructions") |> render_click()

    view
    |> file_input("#source-form", :source_file, [%{name: "rules.md", content: "Tests first."}])
    |> render_upload("rules.md")

    assert has_element?(view, "#source-form textarea", "Tests first.")
    view |> form("#source-form") |> render_submit()
    assert Enum.any?(Sources.list(w.id), &(&1.name == "rules" and &1.content == "Tests first."))

    # Cards on the canvas: an arrow to an agent attaches the source, deleting it detaches.
    {:ok, agent} = Factory.Agents.create_agent(%{name: "Coder", workflow_id: w.id})

    render_hook(view, "attach_source", %{
      "source" => "source-#{source.id}",
      "agent" => "#{agent.id}"
    })

    assert Sources.agent_ids(source) == [agent.id]
    assert_push_event(view, "flow:graph", %{source_links: [%{source: "source-" <> _}]})

    render_hook(view, "detach_source", %{
      "source" => "source-#{source.id}",
      "agent" => "#{agent.id}"
    })

    assert Sources.agent_ids(source) == []

    render_hook(view, "move_sources", %{
      "nodes" => [%{"id" => "source-#{source.id}", "x" => -500, "y" => 40}]
    })

    assert %{x: -500.0, y: 40.0} = Sources.get(source.id)

    render_hook(view, "sources_open", %{})
    view |> element("#source-#{source.id} button[phx-click=source_edit]") |> render_click()
    # The form's ticks attach it too.
    view
    |> form("#source-form", source: %{name: "Design docs", agents: ["#{agent.id}"]})
    |> render_submit()

    assert Sources.get(source.id).name == "Design docs"
    assert Sources.agent_ids(source) == [agent.id]

    view |> element("#source-#{source.id} input[phx-click=source_toggle]") |> render_click()
    refute Sources.get(source.id).enabled

    # Deleting its card on the canvas removes it.
    render_hook(view, "delete_sources", %{"ids" => ["source-#{source.id}"]})
    assert Sources.get(source.id) == nil

    # Another workflow has its own sources.
    {:ok, _view, html} = live(conn, ~p"/workflows/#{Workflows.standard("bug").id}")
    assert html =~ "&quot;sources&quot;:[]"
  end

  test "Browse picks a folder or file instead of typing its path", %{conn: conn} do
    {:ok, w} = Workflows.create("Browse flow")
    root = Path.join(System.tmp_dir!(), "factory-browse-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "design-docs/nested"))
    File.write!(Path.join(root, "design-docs/00-index.md"), "- a.md")
    File.write!(Path.join(root, "design-docs/image.png"), "")
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, view, _html} = live(conn, ~p"/workflows/#{w.id}?sources")
    view |> element("#pick-source-folder") |> render_click()

    view |> element("#browse-path") |> render_click()
    assert has_element?(view, "#file-browser", "Choose a folder")
    render_click(view, "browse_go", %{"path" => root})
    assert has_element?(view, "#browser-entries", "design-docs")
    render_click(view, "browse_go", %{"path" => Path.join(root, "design-docs")})
    # Folders only when choosing a folder.
    assert has_element?(view, "#browser-entries", "nested")
    refute has_element?(view, "#browser-entries", "00-index.md")

    view |> element("#browse-choose") |> render_click()
    refute has_element?(view, "#file-browser")
    assert has_element?(view, ~s(input[name="source[config][path]"][value="#{root}/design-docs"]))
    # It was nameless, so it's named after the folder.
    assert has_element?(view, ~s(input[name="source[name]"][value="design-docs"]))
    view |> form("#source-form") |> render_submit()
    assert [%{name: "design-docs", config: %{"path" => _}}] = Sources.list(w.id)

    # A meta index picks a text file; other files aren't offered.
    render_hook(view, "sources_open", %{"add" => "true"})
    view |> element("#pick-source-meta_index") |> render_click()
    view |> element("#browse-path") |> render_click()
    render_click(view, "browse_go", %{"path" => Path.join(root, "design-docs")})
    assert has_element?(view, "#browser-entries", "00-index.md")
    refute has_element?(view, "#browser-entries", "image.png")
    render_click(view, "browse_pick", %{"path" => Path.join(root, "design-docs/00-index.md")})
    assert has_element?(view, ~s(input[name="source[name]"][value="00-index"]))
    assert has_element?(view, ~s(input[name="source[config][path]"][value$="00-index.md"]))
  end

  test "a PageIndex tree is picked with the browser, which shows only .json files", %{conn: conn} do
    {:ok, w} = Workflows.create("Manual flow")
    dir = Path.join(System.tmp_dir!(), "factory-pi-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    File.write!(
      Path.join(dir, "manual.json"),
      JSON.encode!([%{"title" => "Intro", "node_id" => "0001"}])
    )

    File.write!(Path.join(dir, "notes.md"), "x")

    {:ok, view, _html} = live(conn, ~p"/workflows/#{w.id}?sources")
    assert has_element?(view, "#pick-source-pageindex", "PageIndex")
    view |> element("#pick-source-pageindex") |> render_click()

    view |> element("#browse-path") |> render_click()
    assert has_element?(view, "#file-browser", "Choose a PageIndex tree")
    render_click(view, "browse_go", %{"path" => dir})
    assert has_element?(view, "#browser-entries", "manual.json")
    refute has_element?(view, "#browser-entries", "notes.md")

    render_click(view, "browse_pick", %{"path" => Path.join(dir, "manual.json")})
    view |> form("#source-form") |> render_submit()
    assert [%{kind: "pageindex", name: "manual"}] = Sources.list(w.id)
  end

  test "a source opened from its card closes on Save, and from the list goes back to it",
       %{conn: conn} do
    {:ok, w} = Workflows.create("Card flow")

    {:ok, source} =
      Sources.create(w.id, %{kind: "instructions", name: "Rules", content: "Be brief."})

    {:ok, view, _html} = live(conn, ~p"/workflows/#{w.id}")

    # A click on the card on the canvas.
    render_hook(view, "source_edit", %{"id" => "#{source.id}"})
    view |> form("#source-form", source: %{name: "House rules"}) |> render_submit()
    assert Sources.get(source.id).name == "House rules"
    refute has_element?(view, "#sources-window")

    # Back also just closes it.
    render_hook(view, "source_edit", %{"id" => "#{source.id}"})
    view |> element("#source-form button[phx-click=source_back]") |> render_click()
    refute has_element?(view, "#sources-window")

    # Opened from the list, Save goes back to the list.
    render_hook(view, "sources_open", %{})
    view |> element("#source-#{source.id} button[phx-click=source_edit]") |> render_click()
    view |> form("#source-form", source: %{name: "Rules"}) |> render_submit()
    assert has_element?(view, "#sources")
  end

  test "an arrow's hand-off prompt is added, edited and removed", %{conn: conn} do
    {:ok, w} = Workflows.create("Prompt flow")
    {:ok, a} = Factory.Agents.create_agent(%{name: "Coder", workflow_id: w.id})
    {:ok, b} = Factory.Agents.create_agent(%{name: "Tester", workflow_id: w.id})
    {:ok, link} = Factory.Agents.link(a.id, b.id)
    {:ok, view, _html} = live(conn, ~p"/workflows/#{w.id}")

    # The + on the arrow.
    render_hook(view, "link_prompt_edit", %{"id" => "l#{link.id}"})
    assert has_element?(view, "#link-prompt-title", "Coder")
    refute has_element?(view, "#link-prompt-remove")

    view
    |> form("#link-prompt-form", prompt: "  List the files you changed.  ")
    |> render_submit()

    refute has_element?(view, "#link-prompt-window")
    assert Factory.Agents.get_link(link.id).prompt == "List the files you changed."
    assert_push_event(view, "flow:graph", %{edges: [%{prompt: "List the files you changed."}]})

    render_hook(view, "link_prompt_edit", %{"id" => "l#{link.id}"})
    assert has_element?(view, "#link-prompt-text", "List the files you changed.")
    view |> element("#link-prompt-remove") |> render_click()
    assert Factory.Agents.get_link(link.id).prompt == ""
  end
end
