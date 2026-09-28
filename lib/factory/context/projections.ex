defmodule Factory.Context.Projections do
  @moduledoc """
  The sections of a compacted conversation, ported from pi-fabric
  (`src/compaction/projections.ts`) and fitted to what a Kiro session records:

    * `%{kind: :user, id:, who:, text:}` - a message to an agent (`who`)
    * `%{kind: :assistant, id:, who:, text:}` - the agent's reply
    * `%{kind: :tool, id:, who:, tool:, title:, paths:, outcome:}` - a tool Kiro used;
      `tool` is the ACP kind (read, edit, search, execute…), `outcome` "ok", "failed",
      "denied" or "pending"
    * `%{kind: :error, id:, who:, text:}` - a turn that ended in an error

  Only these fields drive the sections: kinds, outcomes, paths, ids and order. No
  pattern is matched against what anyone wrote. Long lists keep their earliest and
  latest items and say how many were left out, and between which entries.
  """
  alias Factory.Context.{Bounds, Dialogue}

  @max_requests 24
  @max_files_per_kind 24
  @max_unresolved 24
  @max_resolved 8
  @max_earlier_turns 32
  @transcript_window 40

  @modifying ~w(edit delete move)
  @reading ~w(read search fetch)

  @doc "The sections, each a list of lines, and how much each left out."
  def project(events, tail \\ []) do
    exchanges = Dialogue.recent(events, tail)
    {dialogue, dialogue_bytes} = Dialogue.project(exchanges)
    protected = MapSet.new(exchanges, & &1.user.id)
    {requests, requests_omitted} = requests(events, protected)
    {files, files_omitted} = files(events)
    {outstanding, outstanding_omitted} = outstanding(events)
    {earlier, earlier_omitted} = earlier_turns(events)
    {transcript, transcript_omitted} = transcript(events)

    %{
      sections: %{
        dialogue: dialogue,
        requests: requests,
        files: files,
        outstanding: outstanding,
        earlier_turns: earlier,
        status: status(events),
        transcript: transcript
      },
      omitted: %{
        dialogue_bytes: dialogue_bytes,
        requests: requests_omitted,
        files: files_omitted,
        outstanding: outstanding_omitted,
        earlier_turns: earlier_omitted,
        transcript: transcript_omitted
      }
    }
  end

  # Earlier messages are evidence of what was asked, not the task as it stands now.
  defp requests(events, protected) do
    sample =
      events
      |> Enum.filter(&(&1.kind == :user and not MapSet.member?(protected, &1.id)))
      |> Bounds.sample(@max_requests)

    lines =
      Bounds.sampled_lines(sample, "earlier messages", fn user ->
        case Bounds.truncate(Bounds.first_line(user.text), 120) do
          "" -> []
          line -> "- #{line} (to #{user.who}) [entry #{user.id}]"
        end
      end)

    {lines, sample.omitted}
  end

  # Files from tools that worked, each under its first entry. A file changed isn't also listed as read.
  defp files(events) do
    ops = for %{kind: :tool, outcome: "ok"} = e <- events, path <- e.paths, do: {e, path}
    first = fn kinds -> ops |> Enum.filter(&(elem(&1, 0).tool in kinds)) |> firsts() end

    modified = first.(~w(edit move))
    deleted = first.(~w(delete))
    changed = MapSet.new(modified ++ deleted, & &1.path)
    read = first.(@reading) |> Enum.reject(&MapSet.member?(changed, &1.path))

    kinds = [{"Modified:", modified}, {"Deleted:", deleted}, {"Read:", read}]
    samples = for {label, items} <- kinds, do: {label, Bounds.sample(items, @max_files_per_kind)}
    shown = Enum.flat_map(samples, fn {_, s} -> s.values end)

    if shown == [] do
      {[], 0}
    else
      root = common_root(Enum.map(shown, & &1.path))

      lines =
        [if(root != "", do: "(under #{root})")] ++
          Enum.flat_map(samples, fn
            {_label, %{values: [], omitted: 0}} ->
              []

            {label, sample} ->
              [
                label
                | Bounds.sampled_lines(sample, "file addresses", fn f ->
                    "  #{strip_root(root, f.path)} [entry #{f.id}]"
                  end)
              ]
          end)

      {Enum.reject(lines, &is_nil/1),
       samples |> Enum.map(fn {_, s} -> s.omitted end) |> Enum.sum()}
    end
  end

  defp firsts(ops) do
    {items, _} =
      Enum.reduce(ops, {[], MapSet.new()}, fn {e, path}, {acc, seen} ->
        if MapSet.member?(seen, path),
          do: {acc, seen},
          else: {[%{id: e.id, path: path} | acc], MapSet.put(seen, path)}
      end)

    Enum.reverse(items)
  end

  # Tools that failed or were denied, and turns that ended in an error. One counts as
  # resolved when the same tool later worked on the same path (or title), or the same
  # agent later replied.
  defp outstanding(events) do
    indexed = Enum.with_index(events)

    items =
      for {e, i} <- indexed, failure?(e) do
        resolved =
          Enum.any?(indexed, fn {later, j} -> j > i and resolves?(later, e) end)

        %{id: e.id, line: failure_line(e), resolved: resolved}
      end

    {resolved, open} = Enum.split_with(items, & &1.resolved)
    open_sample = Bounds.sample(open, @max_unresolved)
    resolved_sample = Bounds.sample(resolved, @max_resolved)

    line = fn item ->
      "- #{item.line}#{if item.resolved, do: " [RESOLVED]"} [entry #{item.id}]"
    end

    {Bounds.sampled_lines(open_sample, "open error records", line) ++
       Bounds.sampled_lines(resolved_sample, "resolved error records", line),
     open_sample.omitted + resolved_sample.omitted}
  end

  defp failure?(%{kind: :tool, outcome: outcome}), do: outcome in ["failed", "denied"]
  defp failure?(%{kind: :error}), do: true
  defp failure?(_), do: false

  defp resolves?(%{kind: :tool, outcome: "ok"} = later, %{kind: :tool} = e),
    do: tool_key(later) == tool_key(e)

  defp resolves?(%{kind: :assistant, who: who}, %{kind: :error, who: who}), do: true
  defp resolves?(_later, _e), do: false

  defp tool_key(%{tool: tool, paths: [path | _]}), do: {:file, tool, path}
  defp tool_key(%{tool: tool, title: title}), do: {:tool, tool, title}

  defp failure_line(%{kind: :tool} = e) do
    subject =
      case e.paths do
        [path | _] -> "#{e.tool} #{path}"
        [] -> "#{e.tool}: #{Bounds.truncate(e.title, 140)}"
      end

    "#{subject}: #{e.outcome} (#{e.who})"
  end

  defp failure_line(%{kind: :error} = e),
    do: "#{e.who}: #{Bounds.truncate(Bounds.first_line(e.text), 140)}"

  # One line per message before the last summarized one (Current Status has that):
  # its first line and the tools used answering it.
  defp earlier_turns(events) do
    turns =
      events
      |> Enum.chunk_while(
        nil,
        fn
          %{kind: :user} = e, nil -> {:cont, %{user: e, tools: []}}
          %{kind: :user} = e, turn -> {:cont, turn, %{user: e, tools: []}}
          _e, nil -> {:cont, nil}
          %{kind: :tool} = e, turn -> {:cont, %{turn | tools: turn.tools ++ [e.tool]}}
          _e, turn -> {:cont, turn}
        end,
        # The last turn isn't finished by a newer message, so it isn't an earlier one.
        fn _last -> {:cont, nil} end
      )
      |> Enum.map(fn turn ->
        tools =
          turn.tools
          |> Enum.frequencies()
          |> then(fn counts ->
            turn.tools |> Enum.uniq() |> Enum.map_join(" ", &"#{&1}:#{counts[&1]}")
          end)

        text = JSON.encode!(Bounds.truncate(Bounds.first_line(turn.user.text), 80))

        %{
          id: turn.user.id,
          line: "#{text} → #{turn.user.who}#{if tools != "", do: " | #{tools}"}"
        }
      end)

    sample = Bounds.sample(turns, @max_earlier_turns)

    {Bounds.sampled_lines(sample, "earlier turns", &"#{&1.line} [entry #{&1.id}]"),
     sample.omitted}
  end

  # A bridge into the word-for-word tail: the last message, file change and reply summarized.
  defp status(events) do
    reversed = Enum.reverse(events)
    user = Enum.find(reversed, &(&1.kind == :user))

    change =
      Enum.find(reversed, &(&1.kind == :tool and &1.outcome == "ok" and &1.tool in @modifying))

    reply = Enum.find(reversed, &(&1.kind == :assistant))

    [
      user &&
        "Last message: #{Bounds.truncate(Bounds.first_line(user.text), 140)} (to #{user.who})",
      change && "Last change: #{change.tool} #{Enum.join(change.paths, ", ")}",
      reply &&
        case Bounds.truncate(Bounds.first_line(reply.text), 140) do
          "" -> nil
          text -> "Last note: #{text} (#{reply.who})"
        end
    ]
    |> Enum.reject(&(&1 in [nil, false]))
  end

  # The latest events as one-liners, each with its entry.
  defp transcript(events) do
    window = Enum.take(events, -@transcript_window)
    omitted = length(events) - length(window)

    gap =
      if omitted > 0,
        do: [
          Bounds.omission(
            %{omitted: omitted, first: hd(events).id, last: Enum.at(events, omitted - 1).id},
            "transcript events"
          )
        ],
        else: []

    {gap ++ Enum.map(window, &transcript_line/1), omitted}
  end

  defp transcript_line(%{kind: :user} = e),
    do: "(#{e.id}) to #{e.who}: #{Bounds.truncate(Bounds.first_line(e.text), 100)}"

  defp transcript_line(%{kind: :assistant} = e),
    do: "(#{e.id}) #{e.who}: #{Bounds.truncate(Bounds.first_line(e.text), 100)}"

  defp transcript_line(%{kind: :tool} = e) do
    target = if e.paths != [], do: Enum.join(e.paths, ", "), else: e.title
    "(#{e.id}) #{e.tool}(#{Bounds.truncate(target, 80)}) → #{e.outcome}"
  end

  defp transcript_line(%{kind: :error} = e),
    do: "(#{e.id}) #{e.who} error: #{Bounds.truncate(Bounds.first_line(e.text), 100)}"

  # The longest shared leading folders, with a trailing slash; "" when none.
  defp common_root(paths) do
    [first | rest] = Enum.map(paths, &String.split(&1, ["/", "\\"], trim: true))

    common =
      first
      |> Enum.with_index()
      |> Enum.take_while(fn {seg, i} -> Enum.all?(rest, &(Enum.at(&1, i) == seg)) end)
      |> length()

    # A lone file's own name isn't a root.
    common = if rest == [], do: max(common - 1, 0), else: min(common, shortest(paths) - 1)
    lead = if String.starts_with?(hd(paths), "/"), do: "/", else: ""
    if common == 0, do: "", else: lead <> Enum.join(Enum.take(first, common), "/") <> "/"
  end

  defp shortest(paths),
    do: paths |> Enum.map(&length(String.split(&1, ["/", "\\"], trim: true))) |> Enum.min()

  defp strip_root("", path), do: path
  defp strip_root(root, path), do: String.replace_prefix(path, root, "")
end
