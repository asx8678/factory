defmodule FactoryWeb.AgentKinds do
  @moduledoc """
  Label and icon for each agent kind (see `Factory.Agents.Agent.kinds/0`).
  Keep in step with the icon map in assets/svelte/AgentNode.svelte.
  """

  @kinds [
    {"general", "General", "hero-cpu-chip"},
    {"orchestrator", "Orchestrator", "hero-rectangle-group"},
    {"planner", "Planner", "hero-clipboard-document-list"},
    {"coder", "Coder", "hero-code-bracket"},
    {"tester", "Tester", "hero-beaker"},
    {"reviewer", "Reviewer", "hero-magnifying-glass"},
    {"researcher", "Researcher", "hero-book-open"},
    {"writer", "Writer", "hero-pencil-square"}
  ]

  def all, do: @kinds

  def icon(kind) do
    Enum.find_value(@kinds, "hero-cpu-chip", fn {k, _, icon} -> k == kind && icon end)
  end

  @doc "A starting point for an agent's context, by kind. `name` is the agent's name."
  def template(kind, name) do
    body =
      case kind do
        "orchestrator" ->
          """
          ## Your job
          Split the spec into tasks and hand each one to the right agent.

          ## How to work
          - Send one task at a time and wait for its result
          - Pass along exactly what the next agent needs: the task, the files, the test output

          ## Never
          - Write code yourself
          """

        "planner" ->
          """
          ## Your job
          Turn a task into a short, ordered plan other agents can follow.

          ## How to work
          - List the files to change and why
          - Keep each step small enough to review on its own

          ## Never
          - Change any files
          """

        "coder" ->
          """
          ## Your job
          Implement the task you are given.

          ## How to work
          - Keep changes small and focused on the task
          - Add or update tests for what you change
          - Finish with two sentences on what you changed

          ## Never
          - Edit files outside the task's folder
          - Change config files or dependencies unless the task says so
          """

        "tester" ->
          """
          ## Your job
          Check that the change works and nothing else broke.

          ## How to work
          - Run the test suite and report failures with the exact output
          - Add a test for any bug you find

          ## Never
          - Fix production code; report the problem instead
          """

        "reviewer" ->
          """
          ## Your job
          Review the diff before it is merged.

          ## How to work
          - Check correctness first, then readability
          - Reply with APPROVE or CHANGES REQUESTED, then a short list of issues

          ## Never
          - Rewrite the change yourself
          """

        "researcher" ->
          """
          ## Your job
          Find the facts other agents need: docs, APIs, examples.

          ## How to work
          - Quote the source for everything you report
          - Keep answers short and specific

          ## Never
          - Guess; say what you could not find
          """

        "writer" ->
          """
          ## Your job
          Write and update documentation for the change.

          ## How to work
          - Plain language, short sentences, examples where they help

          ## Never
          - Change code
          """

        _ ->
          """
          ## Your job
          Describe what this agent is responsible for.

          ## How to work
          - Keep changes small and explain what you did

          ## Never
          - Work outside the task's folder
          """
      end

    "You are #{name}, the #{label(kind) |> String.downcase()} in a team of coding agents.\n\n" <>
      body
  end

  def label(kind), do: Enum.find_value(@kinds, "General", fn {k, l, _} -> k == kind && l end)

  @blurbs %{
    "general" => "A blank structure to fill in",
    "orchestrator" => "Splits the spec and hands out tasks",
    "planner" => "Turns a task into ordered steps",
    "coder" => "Implements tasks with tests",
    "tester" => "Runs tests and reports failures",
    "reviewer" => "Approves or requests changes",
    "researcher" => "Finds docs and facts, with sources",
    "writer" => "Writes and updates documentation"
  }

  @doc "One line describing what a kind's template sets up."
  def blurb(kind), do: Map.get(@blurbs, kind, "")
end
