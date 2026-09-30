defmodule Factory.Kiro.PermissionTest do
  use ExUnit.Case, async: true

  alias Factory.Kiro.Permission

  @allowed [
    "ls",
    "ls -la lib",
    "cat README.md",
    "git log --oneline -20",
    "git diff main...pr-12",
    "git status",
    "git branch -a",
    "gh pr view 12",
    "gh pr diff 12",
    "mix test",
    "mix test test/factory/permission_test.exs",
    "mix compile",
    "npm test",
    "git log && git diff",
    "cat mix.exs | grep deps",
    "grep -rn foo lib; wc -l lib/factory.ex",
    "sed -n 1,20p lib/factory.ex",
    "find lib -name '*.ex'",
    "elixir --version",
    "node -v",
    "cd lib && ls",
    "mix test 2>&1",
    "ls > /dev/null"
  ]

  @refused [
    "env rm -rf x",
    "env",
    # Settings before a command (GIT_EXTERNAL_DIFF=…) can make it run another program.
    "MIX_ENV=test mix test",
    "FOO=bar ls",
    "ls & rm x",
    "/tmp/x/cat file",
    "/usr/bin/git log",
    "ls > out.txt",
    "echo $(rm x)",
    "echo `rm x`",
    "cat <(rm x)",
    "sed -i s/a/b/ lib/factory.ex",
    "sed --in-place s/a/b/ lib/factory.ex",
    "find . -name '*.tmp' -delete",
    "find . -exec rm {} \\;",
    "git push origin main",
    "git branch new-branch",
    "git checkout main",
    "gh pr merge 12",
    "gh pr comment 12 --body hi",
    "ls | xargs rm",
    "sort -o out.txt in.txt",
    "git diff --output=x.diff",
    "npm install",
    "mix deps.get",
    "rm -rf x",
    "curl https://example.com",
    "unknown-tool --flag",
    ""
  ]

  describe "looking?/1" do
    for command <- @allowed do
      test "allows #{inspect(command)}" do
        assert Permission.looking?(unquote(command))
      end
    end

    for command <- @refused do
      test "refuses #{inspect(command)}" do
        refute Permission.looking?(unquote(command))
      end
    end

    test "refuses an unknown command (nil)" do
      refute Permission.looking?(nil)
    end
  end

  describe "paths/2" do
    test "collects the call's locations and input paths, and those announced earlier" do
      params = %{
        "toolCall" => %{
          "toolCallId" => "c1",
          "locations" => [%{"path" => "lib/a.ex"}, %{"path" => "lib/b.ex"}],
          "rawInput" => %{"path" => "lib/a.ex"}
        }
      }

      assert Permission.paths(params, %{"c1" => ["README.md"]}) == [
               "lib/a.ex",
               "lib/b.ex",
               "README.md"
             ]

      assert Permission.paths(%{"toolCall" => %{"rawInput" => %{"paths" => ["x", "y"]}}}) ==
               ["x", "y"]

      assert Permission.paths(%{"toolCall" => %{"rawInput" => %{"command" => "ls"}}}) == []
      assert Permission.paths(%{}) == []
    end
  end

  describe "allowed_path?/3" do
    @workdir "/home/me/project"
    @roots ["/home/me/sources/docs", "/srv/clones/"]

    test "the project folder and the roots, relative or absolute" do
      assert Permission.allowed_path?("lib/a.ex", @workdir, @roots)
      assert Permission.allowed_path?(".", @workdir, @roots)
      assert Permission.allowed_path?("/home/me/project", @workdir, @roots)
      assert Permission.allowed_path?("/home/me/project/_build/dev/x", @workdir, @roots)
      assert Permission.allowed_path?("deps/phoenix/mix.exs", @workdir, @roots)
      assert Permission.allowed_path?("lib/../.git/config", @workdir, @roots)
      assert Permission.allowed_path?("/home/me/sources/docs/guide.md", @workdir, @roots)
      assert Permission.allowed_path?("../sources/docs/guide.md", @workdir, @roots)
      assert Permission.allowed_path?("/srv/clones/owner/repo/lib", @workdir, @roots)
    end

    test "anything else, however it's spelled" do
      refute Permission.allowed_path?("/etc/passwd", @workdir, @roots)
      refute Permission.allowed_path?("../../.ssh/id_rsa", @workdir, @roots)
      refute Permission.allowed_path?("lib/../../other", @workdir, @roots)
      refute Permission.allowed_path?("/home/me/project-2/lib", @workdir, @roots)
      refute Permission.allowed_path?("/home/me/sources/docs-private/x", @workdir, @roots)
      refute Permission.allowed_path?("~/.bashrc", @workdir, @roots)
      refute Permission.allowed_path?("/home/me", @workdir, @roots)
      refute Permission.allowed_path?(nil, @workdir, @roots)
      refute Permission.allowed_path?("lib/a.ex", nil, @roots)
    end

    test "empty and missing roots are ignored" do
      assert Permission.allowed_path?("lib/a.ex", @workdir, [nil, ""])
      refute Permission.allowed_path?("/etc/hosts", @workdir, [nil, ""])
    end
  end

  describe "looking?/2 in a repository cloned for review" do
    test "the tests and checks aren't looking there" do
      dir = Path.join([Factory.Repos.root(), "owner", "repo"])

      refute Permission.looking?("mix test", dir)
      refute Permission.looking?("MIX_ENV=test mix test", dir)
      refute Permission.looking?("mix compile", dir)
      refute Permission.looking?("npm test", dir)
      refute Permission.looking?("git log && mix test", dir)
    end

    test "reading still is" do
      dir = Path.join([Factory.Repos.root(), "owner", "repo"])

      assert Permission.looking?("git log main..pr-12", dir)
      assert Permission.looking?("git diff main...pr-12", dir)
      assert Permission.looking?("ls", dir)
    end

    test "the tests are looking in any other folder" do
      assert Permission.looking?("mix test", "/tmp/some/project")
      assert Permission.looking?("mix test", nil)
    end
  end
end
