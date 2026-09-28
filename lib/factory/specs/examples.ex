defmodule Factory.Specs.Examples do
  @moduledoc """
  Example base specs to start from: common rules a team wants every run to follow.
  `install/0` adds the ones that aren't there yet (by name), so it can run any time.
  """
  alias Factory.Specs

  @examples [
    {"Coding standards",
     """
     # Coding standards

     - Follow the conventions already in the project: naming, folder layout, formatting.
     - Keep functions small and focused; one reason to change each.
     - Prefer clear names over comments; comment the *why*, not the *what*.
     - No dead code, commented-out code or debug output in the result.
     - Don't add a dependency when the standard library or an existing one does the job.
     - Handle errors explicitly; never swallow them silently.
     - Run the project's formatter and linter before finishing.
     """},
    {"Testing rules",
     """
     # Testing rules

     - Every change comes with tests that would fail without it.
     - A bug fix starts with a test that reproduces the bug.
     - Test behaviour, not implementation details.
     - Cover the edge cases: empty input, invalid input, limits, failures.
     - Tests are independent and deterministic: no sleeps, no order dependence, no network.
     - The whole test suite passes before the work is done.
     """},
    {"Security basics",
     """
     # Security basics

     - Never commit secrets, tokens or passwords; read them from the environment.
     - Validate and sanitise all input from users and other systems.
     - Use parameterised queries; never build SQL from strings.
     - Escape output shown in the UI; never render user input as raw HTML.
     - Check permissions on the server for every action, not only in the UI.
     - Don't log personal data or credentials.
     """},
    {"Git and pull requests",
     """
     # Git and pull requests

     - Work on a branch, never directly on main.
     - Small commits, each one building and passing tests.
     - Commit messages in the imperative: "Add invoice export", with a short why.
     - The pull request says what changed, why, and how it was tested.
     - Don't mix refactoring with behaviour changes in one commit.
     """},
    {"Accessible UI",
     """
     # Accessible UI

     - Everything works with the keyboard; focus is always visible.
     - Buttons and links have clear labels; icons alone get an accessible name.
     - Text contrast meets WCAG AA (4.5:1 for body text).
     - Form fields have labels, and errors say how to fix them.
     - Respect reduced-motion settings; no information by colour alone.
     - Layouts work from phone width up.
     """},
    {"Documentation",
     """
     # Documentation

     - Update the README when setup, configuration or usage changes.
     - Public functions and modules say what they do and what they return.
     - New configuration or environment variables are documented with an example.
     - Note breaking changes in the changelog.
     """}
  ]

  def all, do: @examples

  @doc "Adds the examples that aren't there yet. Returns how many were added."
  def install do
    have = MapSet.new(Specs.list_base_specs(), & &1.name)

    Enum.count(@examples, fn {name, text} ->
      not MapSet.member?(have, name) and match?({:ok, _}, Specs.create_base_spec(name, text))
    end)
  end
end
