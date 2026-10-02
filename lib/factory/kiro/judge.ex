defmodule Factory.Kiro.Judge do
  @moduledoc """
  Whether a tool may run: the one judgement a session's turn (`Factory.Kiro.Session`),
  a one-off question (`Factory.Kiro.Ask`) and pi (`Factory.Kiro.Permit`, through the
  session) all make, so the rules can't drift apart between them.

  Files are read, searched and changed in the folder and its roots only: a path
  elsewhere (`/etc/passwd`, `~/.ssh`, `../..`, a link out) is refused whatever the
  agent may otherwise do. Then `Factory.Kiro.Permission.decide/4` answers.
  """
  alias Factory.Kiro.Permission

  # Tool kinds that name files.
  @file_kinds ~w(read search edit delete move)

  @doc """
  `{decision, outside}`: the decision `:allow`, `:reject`, `{:ask, reason}`, or
  `:outside` with the paths outside `who.folder` and `who.roots`. `who` is
  `Permission.decide/4`'s. Options:

    * `:ask_outside` - a read or search outside goes to `decide/4` (which asks the
      person, for an agent that only reads) instead of being refused
    * `:check_paths` - false skips the check of where the paths lead (a session
      between turns, which has no folder of its own to keep to)
  """
  def judge(kind, command, paths, who, opts \\ []) do
    outside =
      if kind in @file_kinds and Keyword.get(opts, :check_paths, true),
        do: Enum.reject(paths, &Permission.allowed_path?(&1, who.folder, who.roots)),
        else: []

    asks? = Keyword.get(opts, :ask_outside, false) and kind in ["read", "search"]

    if outside != [] and not asks?,
      do: {:outside, outside},
      else: {Permission.decide(kind, command, paths, who), outside}
  end
end
