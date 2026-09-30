defmodule Factory.Sources.Git do
  @moduledoc false

  # git with a deadline; one that overruns is killed with ssh or any helper it started.
  def run(args, env, timeout) do
    executable = Application.get_env(:factory, :sources_git_executable) || "git"
    Factory.OsProcess.run(executable, args, env: env, timeout: timeout)
  end
end
