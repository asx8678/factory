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
    "MIX_ENV=test mix test",
    "FOO=bar ls",
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
