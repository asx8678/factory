defmodule Factory.Sandbox do
  @moduledoc """
  What keeps an agent away from your files when the rules in `Factory.Kiro.Permission`
  are fooled: the CLI and everything it runs start under `bwrap` (bubblewrap), in a
  filesystem where the home folder is empty but for what's named here. Nothing can be
  written except the CLI's own files, and SSH keys, cloud credentials, gh's token and other
  projects aren't there to read. The CLI's own sign-in and sessions are, as it needs them.

    * `:read_only` - for the agents that only read: the project can't be changed either.
      Network stays on, as Kiro needs it, so this limits what can be read and changed,
      not what can be sent.
    * `:project` - for the verifier: the project is writable, as tests write build files,
      and caches too; the rest of the home folder still isn't there.

  Agents that build run without it, as they use whatever the project's toolchain needs;
  what they run is judged by `Factory.Kiro.Permission`.

  `config :factory, :sandbox, false` or `FACTORY_SANDBOX=off` turns it off. Without `bwrap`
  installed agents run unconfined, and the log says so.
  """
  require Logger

  # Read-only for everyone: toolchains and git's own settings. Not gh's, whose token is in
  # them, nor the rest of ~/.local, where other programs keep what they keep.
  @readable ~w(.local/bin .local/lib .local/share/mise .local/state/mise .config/mise
               .config/git .gitconfig .asdf .cargo .rustup .nvm .volta .pyenv .sdkman .mix
               .hex .m2 .gradle .npm go .tool-versions)
  # The CLIs' own files, which they must write.
  @cli_files ~w(.kiro .local/share/kiro-cli .local/state/kiro-cli .config/kiro .cache/kiro
                .pi)
  # Tests write these.
  @caches ~w(.cache .mix .hex .npm .m2 .gradle .cargo)

  @doc "Whether agents can be confined here."
  def available?, do: enabled?() and bwrap() != nil

  defp enabled? do
    Application.get_env(:factory, :sandbox, true) != false and
      System.get_env("FACTORY_SANDBOX") != "off"
  end

  defp bwrap, do: System.find_executable("bwrap")

  @doc """
  The program to start in place of `cli args`, in `workdir`: `{executable, args}`. `mode` is
  `:read_only`, `:project` or nil for none. `roots` are folders the agent may read besides.
  """
  def wrap(cli, args, _workdir, nil, _roots), do: {cli, args}

  def wrap(cli, args, workdir, mode, roots) when mode in [:read_only, :project] do
    if available?() do
      {bwrap(), mounts(cli, workdir, mode, roots) ++ ["--", cli | args]}
    else
      warn_unconfined()
      {cli, args}
    end
  end

  defp warn_unconfined do
    if enabled?() and not :persistent_term.get({__MODULE__, :warned}, false) do
      :persistent_term.put({__MODULE__, :warned}, true)

      Logger.warning(
        "bwrap isn't installed, so agents that only read run without a sandbox. " <>
          "Install bubblewrap to confine them."
      )
    end
  end

  @doc "The bubblewrap options, without the program they start."
  def mounts(cli, workdir, mode, roots) do
    home = System.user_home!()
    workdir = Path.expand(workdir)
    in_home = fn names -> Enum.map(names, &Path.join(home, &1)) end

    readable = in_home.(@readable) ++ [Path.dirname(cli)]
    writable = in_home.(@cli_files) ++ if(mode == :project, do: in_home.(@caches), else: [])
    project = if mode == :project, do: "--bind", else: "--ro-bind"

    [
      ~w(--die-with-parent --unshare-pid --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp),
      ["--tmpfs", home],
      bind("--ro-bind", readable),
      bind("--bind", writable),
      bind("--ro-bind", Enum.map(roots, &Path.expand/1)),
      [project, workdir, workdir],
      # git refuses a repository's work tree owned by "someone else" no differently here,
      # and a command starts in the project.
      ["--chdir", workdir]
    ]
    |> List.flatten()
  end

  defp bind(flag, paths) do
    paths
    |> Enum.uniq()
    |> Enum.filter(&File.exists?/1)
    |> Enum.flat_map(&[flag, &1, &1])
  end
end
