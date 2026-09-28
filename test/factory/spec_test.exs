defmodule Factory.SpecTest do
  use ExUnit.Case, async: true
  alias Factory.Spec

  test "reads top-level Kiro checklist items and skips sub-items" do
    md = """
    # Implementation Plan

    - [ ] 1. Set up project structure
      - Create the Phoenix app
      - _Requirements: 1.1_
    - [x] 2. Add login page
    - [ ] 2.1 Write tests
    """

    assert Spec.parse_tasks(md) == [
             %{ref: "1", title: "Set up project structure"},
             %{ref: "2", title: "Add login page"},
             %{ref: "2.1", title: "Write tests"}
           ]
  end

  test "falls back to a numbered list" do
    assert Spec.parse_tasks("1. First\n2) Second\n   3. nested") == [
             %{ref: "1", title: "First"},
             %{ref: "2", title: "Second"}
           ]
  end

  test "prefers tasks.md over other files" do
    files = [{"design.md", "1. not a task"}, {"tasks.md", "- [ ] 1. Real task"}]
    assert {"tasks.md", [%{title: "Real task"}]} = Spec.tasks_from_files(files)
  end

  test "reports no tasks" do
    assert Spec.tasks_from_files([{"notes.md", "just prose"}]) == {nil, []}
  end

  test "characters containing the byte 0x85 aren't split as line breaks" do
    text = "- [ ] 1. Add ★ flag\n  - Table with ★ Astra and Åse columns"

    assert [%{title: "Add ★ flag"}] = Spec.parse_tasks(text)
    {[], [block]} = Spec.blocks(text)
    assert block.details == ["Table with ★ Astra and Åse columns"]
    assert String.valid?(Spec.render_blocks([], [block]))
  end
end
