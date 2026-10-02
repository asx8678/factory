defmodule Factory.GitCmd do
  @moduledoc """
  Runs git for `Factory.Repos`, `Factory.Sources` and `Factory.Scout`, in a repository's
  folder or anywhere (`nil`, for `git clone`), with a deadline (`Factory.OsProcess`):
  git that overruns is stopped with ssh and anything else it started.
  """

  # Never waits on a person: no password prompt, and ssh neither asks nor hangs on a
  # host it doesn't know yet.
  @env [
    {"GIT_TERMINAL_PROMPT", "0"},
    {"SSH_ASKPASS_REQUIRE", "never"},
    {"GIT_SSH_COMMAND",
     "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"}
  ]

  @doc """
  Runs `git args` in `dir` (with `git -C dir`, or from the current folder when `dir`
  is nil), as `Factory.OsProcess.run/3` answers: `{:ok, output, exit_status}`,
  `{:error, :timeout}` or `{:error, reason}`. Options: `:env` (`{name, value}` pairs,
  over git's own above), `:timeout` (ms, default 5 minutes) and `:executable`.
  """
  def run(dir, args, opts \\ []) do
    args = if dir, do: ["-C", dir | args], else: args
    env = Enum.uniq_by(Keyword.get(opts, :env, []) ++ @env, &elem(&1, 0))

    Factory.OsProcess.run(Keyword.get(opts, :executable, "git"), args,
      env: env,
      timeout: Keyword.get(opts, :timeout, 300_000)
    )
  end

  @doc """
  A time as git prints it (`--format=%cI`, `committerdate:iso-strict`, or GitHub's
  timestamps) as a `DateTime`, or nil when it isn't one.
  """
  def time(nil), do: nil

  def time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  def time(_), do: nil
end
