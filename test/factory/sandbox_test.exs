defmodule Factory.SandboxTest do
  # Not async: it changes what `config :factory, :sandbox` says.
  use Factory.DataCase, async: false
  alias Factory.{Repos, Sandbox}

  @bwrap System.find_executable("bwrap")

  defp temp do
    dir = Path.join(System.tmp_dir!(), "sandbox-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp run_in(mode, dir, script, roots \\ []) do
    put_app_env(:sandbox, true)
    {exe, args} = Sandbox.wrap("/bin/sh", ["-c", script], dir, mode, roots)
    System.cmd(exe, args, cd: dir, stderr_to_stdout: true)
  end

  test "without a mode, or turned off, it starts the program as it is" do
    assert Sandbox.wrap("cli", ["a"], "/tmp", nil, []) == {"cli", ["a"]}
    put_app_env(:sandbox, false)
    assert Sandbox.wrap("cli", ["a"], "/tmp", :read_only, []) == {"cli", ["a"]}
  end

  if @bwrap do
    test "an agent that only reads can't write, and doesn't see the home folder's secrets" do
      dir = temp()
      File.write!(Path.join(dir, "keep.txt"), "keep\n")

      {out, _} =
        run_in(
          :read_only,
          dir,
          "cat keep.txt; rm keep.txt; echo x > new.txt; ls #{Path.expand("~/.ssh")}; " <>
            "ls #{Path.expand("~/factory")}; echo ok > /tmp/fine; cat /tmp/fine"
        )

      assert out =~ "keep\n"
      assert out =~ "Read-only file system"
      assert out =~ ".ssh': No such file"
      assert out =~ "factory': No such file"
      assert out =~ "ok\n"
      assert File.exists?(Path.join(dir, "keep.txt"))
      refute File.exists?(Path.join(dir, "new.txt"))
    end

    test "its sources are there to read, and nothing else outside" do
      dir = temp()
      source = temp()
      other = Path.join(Path.dirname(dir), "sandbox-other-#{System.unique_integer([:positive])}")
      File.write!(Path.join(source, "doc.md"), "the doc\n")

      {out, _} =
        run_in(:read_only, dir, "cat #{source}/doc.md; echo x > #{source}/w; ls #{other}", [
          source
        ])

      assert out =~ "the doc"
      assert out =~ "Read-only file system"
      refute File.exists?(Path.join(source, "w"))
    end

    test "the verifier can write in the project, as tests do, but not see the secrets" do
      dir = temp()
      {out, 0} = run_in(:project, dir, "echo built > _build; ls #{Path.expand("~/.ssh")} || true")

      assert File.read!(Path.join(dir, "_build")) == "built\n"
      assert out =~ ".ssh': No such file"
    end

    test "what it starts dies with it" do
      dir = temp()
      {_, 0} = run_in(:read_only, dir, "sleep 54321 & exit 0")
      {pids, _} = System.cmd("pgrep", ["-f", "^sleep 54321$"])
      assert pids == ""
    end
  end

  describe "review clones" do
    setup do
      base = temp()
      origin = Path.join(base, "origin")
      File.mkdir_p!(Path.join(origin, ".kiro/settings"))
      File.mkdir_p!(Path.join(origin, ".pi"))
      File.write!(Path.join(origin, ".kiro/settings/mcp.json"), "{}")
      File.write!(Path.join(origin, ".pi/x"), "x")
      File.write!(Path.join(origin, "README.md"), "a repository\n")

      for args <- [
            ~w(init -q -b main),
            ~w(add -A),
            ~w(-c user.email=a@b -c user.name=a commit -qm init)
          ] do
        {_, 0} = System.cmd("git", args, cd: origin, stderr_to_stdout: true)
      end

      put_app_env(:review_dir, Path.join(base, "reviews"))
      {:ok, origin: origin}
    end

    test "keep the repository's agent settings out of the working tree, not its history",
         %{origin: origin} do
      {:ok, %{dir: dir}} = Repos.clone(origin)

      assert File.exists?(Path.join(dir, "README.md"))
      refute File.exists?(Path.join(dir, ".kiro"))
      refute File.exists?(Path.join(dir, ".pi"))
      assert Repos.safe_to_start(dir) == :ok

      {tree, 0} = System.cmd("git", ~w(ls-tree -r --name-only HEAD), cd: dir)
      assert tree =~ ".kiro/settings/mcp.json"
      {status, 0} = System.cmd("git", ~w(status --short), cd: dir)
      assert status == ""
    end

    test "and fetching again keeps them out", %{origin: origin} do
      {:ok, %{dir: dir}} = Repos.clone(origin)
      {:ok, %{fresh: false}} = Repos.clone(origin)
      refute File.exists?(Path.join(dir, ".kiro"))
    end

    test "a clone from before this is put right when a CLI would start in it", %{origin: origin} do
      dir = Path.join([Repos.root(), "local", "old"])
      File.mkdir_p!(Path.dirname(dir))
      {_, 0} = System.cmd("git", ["clone", "-q", origin, dir], stderr_to_stdout: true)
      assert File.exists?(Path.join(dir, ".kiro"))

      assert Repos.safe_to_start(dir) == :ok
      refute File.exists?(Path.join(dir, ".kiro"))
    end

    test "settings that can't be taken out stop the CLI from starting" do
      dir = Path.join([Repos.root(), "local", "not-a-repo"])
      File.mkdir_p!(Path.join(dir, ".kiro"))

      assert {:error, reason} = Repos.safe_to_start(dir)
      assert reason =~ "won't start"
      assert {:error, ^reason} = Factory.Kiro.ask("hello", workdir: dir)
    end

    test "any other folder is the person's own", %{origin: origin} do
      assert Repos.safe_to_start(origin) == :ok
    end
  end

  describe "what the CLI inherits" do
    test "not Factory's secrets" do
      dir = temp()
      System.put_env("GITHUB_TOKEN", "secret-token")
      System.put_env("SOME_PATH_HOME", "x")
      on_exit(fn -> Enum.each(~w(GITHUB_TOKEN SOME_PATH_HOME), &System.delete_env/1) end)
      script = Path.join(dir, "env.sh")
      File.write!(script, "#!/bin/sh\nenv\n")
      File.chmod!(script, 0o755)

      old = Application.fetch_env!(:factory, :kiro)
      Application.put_env(:factory, :kiro, Keyword.put(old, :cli, script))
      on_exit(fn -> Application.put_env(:factory, :kiro, old) end)

      {port, _log} = Factory.Kiro.open_port(dir, "env-test.log", runtime: :kiro)
      out = collect(port, "")

      refute out =~ "secret-token"
      refute out =~ "SOME_PATH_HOME"
      assert out =~ "PATH="
      assert out =~ "HOME="
      assert out =~ "GIT_CONFIG_KEY_0=safe.bareRepository"
    end

    defp collect(port, acc) do
      receive do
        {^port, {:data, {_eol, line}}} -> collect(port, acc <> line <> "\n")
        {^port, {:exit_status, _}} -> acc
      after
        5_000 -> flunk("the script didn't finish")
      end
    end

    test "git won't obey a config file an ordinary folder carries" do
      dir = temp()
      evil = Path.join(dir, "evil")
      marker = Path.join(dir, "RAN")
      File.mkdir_p!(Path.join(evil, "objects"))
      File.mkdir_p!(Path.join(evil, "refs"))
      File.write!(Path.join(evil, "HEAD"), "ref: refs/heads/main\n")

      File.write!(
        Path.join(evil, "config"),
        "[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tworktree = ..\n\t" <>
          "fsmonitor = \"touch #{marker}; false\"\n"
      )

      env = [
        {"GIT_CONFIG_COUNT", "2"},
        {"GIT_CONFIG_KEY_0", "safe.bareRepository"},
        {"GIT_CONFIG_VALUE_0", "explicit"},
        {"GIT_CONFIG_KEY_1", "core.fsmonitor"},
        {"GIT_CONFIG_VALUE_1", "false"}
      ]

      System.cmd("git", ["status"], cd: evil, env: env, stderr_to_stdout: true)
      refute File.exists?(marker)
    end
  end
end
