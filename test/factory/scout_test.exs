defmodule Factory.ScoutTest do
  # Reads a real, throwaway git repository: no database, no Kiro.
  use ExUnit.Case, async: true
  alias Factory.Scout

  @moduletag :tmp_dir

  # A repository on `main` with one commit, then a `feature` branch one commit ahead,
  # with an uncommitted change and a TODO note in a tracked file.
  setup %{tmp_dir: dir} do
    git(dir, ~w(init -q))
    git(dir, ~w(symbolic-ref HEAD refs/heads/main))
    git(dir, ~w(config user.email scout@example.com))
    git(dir, ~w(config user.name Scout))
    git(dir, ~w(config commit.gpgsign false))

    File.write!(Path.join(dir, "notes.txt"), "# TODO: handle the empty list\n")
    File.write!(Path.join(dir, "README.md"), "Hello\n")
    git(dir, ~w(add .))
    git(dir, ~w(commit -q -m First))

    git(dir, ~w(checkout -q -b feature))
    File.write!(Path.join(dir, "feature.txt"), "new\n")
    git(dir, ~w(add feature.txt))
    git(dir, ["commit", "-q", "-m", "Add the feature"])

    File.write!(Path.join(dir, "README.md"), "Hello again\n")
    %{dir: dir}
  end

  test "scout reads the branch, the base, the branches ahead and the changes", %{dir: dir} do
    assert {:ok, scouted} = Scout.scout(dir)
    assert scouted.current == "feature"
    assert scouted.base == "main"
    assert scouted.dirty == 1
    assert Enum.map(scouted.recent, & &1.subject) == ["Add the feature", "First"]
    assert Enum.all?(scouted.recent, &match?(%DateTime{}, &1.at))

    assert Enum.sort(Enum.map(scouted.branches, & &1.name)) == ["feature", "main"]
    feature = Enum.find(scouted.branches, &(&1.name == "feature"))
    assert %{current: true, remote: false, ahead: 1, behind: 0, base: "main"} = feature
    assert feature.subject == "Add the feature"
    assert feature.author == "Scout"
    main = Enum.find(scouted.branches, &(&1.name == "main"))
    assert %{current: false, ahead: 0, behind: 0} = main

    # Pull requests need gh, signed in, and a GitHub remote: none here.
    assert is_nil(scouted.prs) or is_list(scouted.prs)
    assert is_nil(scouted.prs_note) or is_binary(scouted.prs_note)
  end

  test "ideas: the uncommitted changes, the branch ahead, then the notes", %{dir: dir} do
    ideas = Scout.ideas(dir)

    assert Enum.map(ideas, & &1.label) == [
             "Finish the changes in README.md",
             "Carry on with feature",
             "TODO: handle the empty list"
           ]

    assert Enum.at(ideas, 0).text == "Finish the uncommitted changes in `README.md`."
    assert Enum.at(ideas, 1).text =~ "`feature` branch (1 commit ahead of `main`"
    assert Enum.at(ideas, 1).text =~ "“Add the feature”"

    assert Enum.at(ideas, 2).text ==
             "Resolve the note in `notes.txt:1`: “TODO: handle the empty list”."

    # The limit cuts the list from the end.
    assert Enum.map(Scout.ideas(dir, 2), & &1.label) ==
             ["Finish the changes in README.md", "Carry on with feature"]
  end

  test "a folder that isn't a repository, or doesn't exist, is an error" do
    plain = Path.join(System.tmp_dir!(), "scout-plain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(plain)
    on_exit(fn -> File.rm_rf(plain) end)

    assert {:error, "This folder isn't a git repository."} = Scout.scout(plain)
    assert Scout.ideas(plain) == []

    missing = Path.join(plain, "missing")
    assert {:error, "That folder doesn't exist."} = Scout.scout(missing)
    assert Scout.ideas(missing) == []
  end

  defp git(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    out
  end
end
