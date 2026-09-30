defmodule Factory.Specs.TaskCheckTest do
  use ExUnit.Case, async: true
  alias Factory.Specs.TaskCheck

  @good %{
    title: "Add the export button to the invoices page",
    objective: "The invoices page has an Export CSV button",
    details: ["Add a button in `lib/app_web/live/invoices_live.ex`."],
    verify: ["mix test test/app_web/live/invoices_live_test.exs passes"]
  }

  test "a task that says what, where and how to check it has no issues" do
    assert TaskCheck.issues(@good) == []
    refute TaskCheck.thin?(@good)
  end

  test "a bare title is missing everything" do
    assert TaskCheck.issues(%{title: "Export", details: []}) ==
             ["no objective", "no steps", "no code named", "no way to check it", "vague title"]

    assert TaskCheck.thin?(%{title: "Export", details: []})
  end

  test "code is recognised as a file, a module or a function, in the steps or the checks" do
    # A check that names no code, so the steps have to.
    base = %{@good | verify: ["Click the button: a file downloads"]}

    file = %{base | details: ["Add a button in lib/app_web/live/invoices_live.ex."]}
    assert TaskCheck.issues(file) == []

    module = %{base | details: ["Add a button in Invoices.Export."]}
    assert TaskCheck.issues(module) == []

    function = %{base | details: ["Call export_csv/1 from the button."]}
    assert TaskCheck.issues(function) == []

    in_checks = %{base | details: ["Add the button."], verify: ["`mix test` passes"]}
    assert TaskCheck.issues(in_checks) == []

    none = %{base | details: ["Add the button to the page."]}
    assert TaskCheck.issues(none) == ["no code named"]
  end

  test "a check can be among the steps, for tasks written before Verify lines" do
    steps = %{@good | verify: [], details: ["Add a button in `lib/x.ex`.", "Run `mix test`."]}
    assert TaskCheck.issues(steps) == []

    unchecked = %{@good | verify: [], details: ["Add a button in `lib/x.ex`."]}
    assert TaskCheck.issues(unchecked) == ["no way to check it"]
    assert TaskCheck.issues(Map.delete(unchecked, :verify)) == ["no way to check it"]
  end

  test "one gap isn't thin, two are, and no steps always is" do
    one = %{@good | verify: [], details: ["Add a button in `lib/x.ex`."]}
    refute TaskCheck.thin?(one)

    # A missing objective on its own doesn't count either.
    refute TaskCheck.thin?(Map.put(one, :objective, ""))
    refute TaskCheck.thin?(Map.delete(@good, :objective))

    two = %{@good | verify: [], details: ["Add a button on the invoices page."]}
    assert TaskCheck.issues(two) == ["no code named", "no way to check it"]
    assert TaskCheck.thin?(two)

    no_steps = %{@good | details: []}
    assert TaskCheck.issues(no_steps) == ["no steps"]
    assert TaskCheck.thin?(no_steps)
  end

  test "a title of fewer than three words is vague" do
    assert "vague title" in TaskCheck.issues(%{@good | title: "Export button"})
    refute "vague title" in TaskCheck.issues(%{@good | title: "Add export button"})
  end
end
