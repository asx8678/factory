defmodule Factory.ReposTest do
  # Only parsing: cloning needs the network and an SSH key.
  use ExUnit.Case, async: true
  alias Factory.Repos

  test "an SSH address is cloned as written" do
    assert {:ok, repo} = Repos.parse("git@github.com:o/r.git")
    assert repo == %{url: "git@github.com:o/r.git", owner: "o", repo: "r", pr: nil, label: "o/r"}

    assert {:ok, %{url: "ssh://git@host:2222/o/r", owner: "o", repo: "r", pr: nil}} =
             Repos.parse("ssh://git@host:2222/o/r")
  end

  test "a web link to a repository becomes its SSH address" do
    assert {:ok, %{url: "git@github.com:o/r.git", owner: "o", repo: "r", pr: nil, label: "o/r"}} =
             Repos.parse("https://github.com/o/r")

    # With or without .git, a trailing slash, or space around it.
    assert {:ok, %{url: "git@github.com:o/r.git", repo: "r"}} =
             Repos.parse("https://github.com/o/r.git")

    assert {:ok, %{url: "git@github.com:o/r.git", repo: "r"}} =
             Repos.parse("https://github.com/o/r/")

    assert {:ok, %{url: "git@github.com:o/r.git"}} = Repos.parse("  https://github.com/o/r \n")
  end

  test "a pull request's link carries its number" do
    assert {:ok, %{url: "git@github.com:o/r.git", owner: "o", repo: "r", pr: 12, label: "o/r"}} =
             Repos.parse("https://github.com/o/r/pull/12")

    assert {:ok, %{pr: 12}} = Repos.parse("https://github.com/o/r/pull/12/files")
    # Another page of the repository isn't a pull request.
    assert {:ok, %{pr: nil}} = Repos.parse("https://github.com/o/r/tree/main")
  end

  test "a folder on this computer is a local repository" do
    dir = Path.join(System.tmp_dir!(), "factory-repos-#{System.unique_integer([:positive])}.git")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    assert {:ok, repo} = Repos.parse(dir)
    assert repo.url == dir
    assert repo.owner == "local"
    assert repo.repo == Path.basename(dir, ".git")
    assert repo.pr == nil
    assert repo.label == "local/" <> repo.repo

    assert {:ok, %{url: ^dir}} = Repos.parse("file://" <> dir)
  end

  test "a folder that doesn't exist is an error that names it" do
    missing = Path.join(System.tmp_dir!(), "factory-repos-missing-#{System.unique_integer()}")
    assert {:error, reason} = Repos.parse(missing)
    assert reason =~ "There's no folder at #{missing}"
  end

  test "nothing, or something that isn't a link, is refused" do
    assert {:error, "Paste the repository's link."} = Repos.parse("")
    assert {:error, "Paste the repository's link."} = Repos.parse("   ")
    assert {:error, "Paste the repository's link."} = Repos.parse(nil)

    assert {:error, reason} = Repos.parse("just some words")
    assert reason =~ "isn't a repository's link"
    assert {:error, _} = Repos.parse("https://github.com/only-owner")
  end
end
