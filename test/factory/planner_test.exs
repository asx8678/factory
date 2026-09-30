defmodule Factory.Specs.PlannerTest do
  use ExUnit.Case, async: true
  alias Factory.Specs.Planner

  @files [{"requirements.md", "1. Export CSV"}]

  test "every prompt that asks for tasks asks for the one shape" do
    type = %{id: "feature", label: "Build a feature"}
    task = %{title: "Add export", details: [], requirements: []}

    for prompt <- [
          Planner.tasks_prompt(@files, "Phoenix app.", []),
          Planner.run_prompt(type, @files, write: ["tasks"]),
          Planner.chat_prompt("Planner", ["Add export"], @files, nil),
          Planner.improve_prompt(@files, task, ""),
          Planner.draft_prompt(@files, "Add export", "")
        ] do
      assert prompt =~ String.trim_trailing(Planner.task_json(), "}")
    end
  end

  test "a task is normalised the same way whatever wrote it" do
    assert Planner.task(%{
             "title" => " Add\nexport ",
             "details" => "In `lib/a.ex`.\n\nTest it.",
             "requirements" => [1.2, "2"]
           }) == %{
             "title" => "Add export",
             "objective" => "",
             "details" => ["In `lib/a.ex`.", "Test it."],
             "verify" => [],
             "model" => nil,
             "requirements" => ["1.2", "2"]
           }

    assert Planner.task(%{"title" => "  "}) == nil
    assert Planner.task(%{"details" => ["x"]}) == nil

    reply = ~s({"tasks": [{"title": "A", "details": "One.", "size": "M"}, {"title": ""}]})

    assert {:ok, [%{"title" => "A", "details" => ["One."], "requirements" => [], "size" => "M"}]} =
             Planner.parse_tasks(reply)

    assert {:ok, %{title: "A", details: ["One."], requirements: []}} =
             Planner.parse_improvement(~s({"title": "A", "details": ["One."]}))

    assert {:ok, %{tasks: [%{"details" => ["One."], "requirements" => ["1"]}]}} =
             Planner.parse_chat_plan(
               ~s({"reply": "ok", "tasks": [{"title": "A", "details": ["One."], "requirements": ["1"]}]})
             )
  end
end
