defmodule Factory.GitCmd do
  @moduledoc """
  Runs git for `Factory.Repos` and `Factory.Scout`, in a repository's folder or
  anywhere (`nil`, for `git clone`). Output and errors come back raw, with the
  surrounding space trimmed, for each caller to explain in its own words.
  """

  @doc """
  Runs `git args` in `dir` (with `git -C dir`, or from the current folder when `dir`
  is nil): `{:ok, output}` when git exits 0, `{:error, output}` when it doesn't (stderr
  is in the output), or `{:error, :not_installed}` when there's no git to run.

  `env:` in `opts` is a list of `{name, value}` pairs for git's environment, such as
  `GIT_SSH_COMMAND`.
  """
  def run(dir, args, opts \\ []) do
    args = if dir, do: ["-C", dir | args], else: args
    env = Keyword.get(opts, :env, [])

    case System.cmd("git", args, stderr_to_stdout: true, env: env) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, String.trim(out)}
    end
  rescue
    # System.cmd raises ErlangError (:enoent) when there's no git on the PATH.
    _ -> {:error, :not_installed}
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
