defmodule Factory.PageIndexTest do
  use Factory.DataCase, async: false
  alias Factory.{Agents, Sources, Workflows}
  alias Factory.Sources.PageIndex

  @tree %{
    "doc_name" => "manual.pdf",
    "structure" => [
      %{
        "title" => "Getting started",
        "node_id" => "0001",
        "start_index" => 1,
        "end_index" => 4,
        "summary" => "Installing and first run.",
        "text" => "Run the installer.",
        "nodes" => [
          %{
            "title" => "Requirements",
            "node_id" => "0002",
            "start_index" => 2,
            "end_index" => 2,
            "text" => "8 GB of memory."
          }
        ]
      },
      %{"title" => "Billing", "node_id" => "0003", "start_index" => 5, "end_index" => 9}
    ]
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "factory-pageindex-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "manual_structure.json")
    File.write!(path, JSON.encode!(@tree))
    %{dir: dir, path: path}
  end

  test "reads a tree, as an object or a bare list", %{dir: dir, path: path} do
    assert {:ok, %{doc_name: "manual.pdf", count: 3, text?: true} = tree} = PageIndex.load(path)

    assert PageIndex.outline(tree.nodes) ==
             """
             - [0001] Getting started (p. 1–4): Installing and first run.
               - [0002] Requirements (p. 2)
             - [0003] Billing (p. 5–9)\
             """

    list = Path.join(dir, "list.json")
    File.write!(list, JSON.encode!(@tree["structure"]))
    assert {:ok, %{doc_name: "list", count: 3}} = PageIndex.load(list)

    bad = Path.join(dir, "bad.json")
    File.write!(bad, "{not json")
    assert {:error, "isn't valid JSON"} = PageIndex.load(bad)
    File.write!(bad, ~s({"structure": []}))
    assert {:error, "isn't a PageIndex tree: no sections found"} = PageIndex.load(bad)
  end

  test "an attached PageIndex gives the agent the outline and a file per section", %{
    path: path,
    dir: dir
  } do
    {:ok, w} = Workflows.create("Docs")

    assert {:error, cs} =
             Sources.create(w.id, %{
               kind: "pageindex",
               name: "Manual",
               config: %{"path" => Path.join(dir, "nope.json")}
             })

    assert [{:config, {"isn't a file on this machine", [field: "path"]}}] = cs.errors

    {:ok, source} =
      Sources.create(w.id, %{kind: "pageindex", name: "Manual", config: %{"path" => path}})

    {:ok, agent} = Agents.create_agent(%{name: "Support", workflow_id: w.id})
    {:ok, _} = Sources.attach(source, agent.id)

    text = Sources.context_for_agent(agent)
    assert text =~ ~s(## PageIndex "Manual")
    assert text =~ ~s[A table of contents of "manual.pdf" (3 sections)]
    assert text =~ "- [0003] Billing (p. 5–9)"

    [_, file] = Regex.run(~r/\[0002\] Requirements \(p\. 2\) → (\S+)/, text)
    assert File.read!(file) == "# Requirements (p. 2)\n\n8 GB of memory.\n"
    # Sections without text have no file; the outline still lists them.
    refute text =~ ~r/Billing \(p\. 5–9\) →/

    # Removing the source removes its section files.
    {:ok, _} = Sources.delete(source)
    refute File.exists?(file)
  end

  test "without section text, agents are pointed at the document", %{dir: dir} do
    tree = Path.join(dir, "bare.json")

    File.write!(
      tree,
      JSON.encode!([
        %{"title" => "Intro", "node_id" => "0001", "start_index" => 1, "end_index" => 2}
      ])
    )

    doc = Path.join(dir, "manual.pdf")
    File.write!(doc, "%PDF")
    {:ok, w} = Workflows.create("Docs")

    {:ok, _} =
      Sources.create(w.id, %{
        kind: "pageindex",
        name: "Manual",
        config: %{"path" => tree, "document" => doc}
      })

    assert Sources.context(w.id) =~
             "Read only the pages the task needs from the document at #{doc}"
  end
end
