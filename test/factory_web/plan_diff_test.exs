defmodule FactoryWeb.PlanDiffTest do
  use ExUnit.Case, async: true
  alias FactoryWeb.PlanDiff

  @button %{
    title: "Add the export button to the invoices page",
    objective: "The invoices page has an Export CSV button",
    details: ["In `lib/app_web/live/invoices_live.ex`."],
    verify: ["The button shows on /invoices"],
    requirements: ["1.1"]
  }

  @csv %{
    title: "Write the CSV for the invoices shown",
    details: ["New `lib/app/invoices/csv.ex`.", "Test it in `test/app/invoices/csv_test.exs`."],
    requirements: []
  }

  test "a snapshot keeps each task's parts, filling in the ones a task lacks" do
    [button, csv] = PlanDiff.snapshot([@button, @csv])
    assert button.title == @button.title
    assert button.verify == ["The button shows on /invoices"]
    assert csv.objective == nil
    assert csv.verify == []
    assert csv.agent == nil
    assert csv.model == nil
  end

  test "nothing is marked when nothing changed, or without a snapshot" do
    snapshot = PlanDiff.snapshot([@button, @csv])
    assert PlanDiff.diff(snapshot, [@button, @csv]) == {[nil, nil], []}
    assert PlanDiff.diff(nil, [@button, @csv]) == {[nil, nil], []}
  end

  test "a task the snapshot doesn't have is new; every task is, against an empty snapshot" do
    snapshot = PlanDiff.snapshot([@button])

    empty = %{
      title: "Test an empty month",
      details: ["Returns just the header row."],
      requirements: []
    }

    assert {[nil, %{new: true}], []} = PlanDiff.diff(snapshot, [@button, empty])
    assert {[%{new: true}, %{new: true}], []} = PlanDiff.diff([], [@button, @csv])
  end

  test "a snapshot task that's gone is listed by title" do
    snapshot = PlanDiff.snapshot([@button, @csv])
    assert PlanDiff.diff(snapshot, [@button]) == {[nil], [@csv.title]}
  end

  test "a renamed task is matched by the words it shares, and marked as retitled" do
    snapshot = PlanDiff.snapshot([@button, @csv])
    renamed = %{@button | title: "Add an Export CSV button to the invoices page"}

    assert {[mark, nil], []} = PlanDiff.diff(snapshot, [renamed, @csv])
    assert %{new: false, title: true, objective: false, steps: [], checks: []} = mark
  end

  test "changed steps and checks are marked by the index of the new lines" do
    snapshot = PlanDiff.snapshot([@button])

    changed = %{
      @button
      | details: ["Read the invoices first.", "In `lib/app_web/live/invoices_live.ex`."],
        verify: ["The button shows on /invoices", "Clicking it downloads a file"]
    }

    assert {[mark], []} = PlanDiff.diff(snapshot, [changed])
    assert mark.title == false
    assert mark.steps == [0]
    assert mark.checks == [1]

    # Only the objective, or the agent, changing marks that alone.
    assert {[%{objective: true, steps: [], checks: []}], []} =
             PlanDiff.diff(snapshot, [%{@button | objective: "Invoices export as CSV"}])

    assert {[%{agent: true, model: false}], []} =
             PlanDiff.diff(snapshot, [Map.put(@button, :agent, "Coder")])
  end

  test "the person's own edit is taken into the snapshot, so it isn't marked" do
    snapshot = PlanDiff.snapshot([@button, @csv])
    edited = %{@button | title: "Add the export button"}

    accepted = PlanDiff.accept(snapshot, [@button, @csv], [edited, @csv], 0, :edit)
    assert PlanDiff.diff(accepted, [edited, @csv]) == {[nil, nil], []}

    removed = PlanDiff.accept(snapshot, [@button, @csv], [@csv], 0, :remove)
    assert PlanDiff.diff(removed, [@csv]) == {[nil], []}

    assert PlanDiff.accept(nil, [@button], [edited], 0, :edit) == nil
  end
end
